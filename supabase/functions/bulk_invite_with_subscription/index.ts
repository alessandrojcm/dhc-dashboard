import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import dayjs from 'https://esm.sh/dayjs@1.11.7';
import * as Sentry from 'https://esm.sh/@sentry/node@7.64.0';
import { Stripe } from 'https://esm.sh/stripe@12.4.0?target=deno';
import type { Stripe as StripeType } from 'https://esm.sh/v135/stripe@12.4.0/types/index.d.ts';
import { db } from '../_shared/db.ts';
import { createInvitation } from '../_shared/invitations.ts';
import { createPaymentSession, updateUserProfileWithCustomerId } from '../_shared/subscriptions.ts';

// Initialize Sentry
Sentry.init({
  dsn: Deno.env.get('SENTRY_DSN'),
  environment: Deno.env.get('ENVIRONMENT') || 'development',
  tracesSampleRate: 1.0
});

// Initialize Stripe client
const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') || '', {
  apiVersion: '2023-10-16',
  httpClient: Stripe.createFetchHttpClient()
});

// Define types for our application
interface InviteData {
  firstName: string;
  lastName: string;
  email: string;
  phoneNumber: string;
  dateOfBirth: string | Date;
}

interface UserData {
  id: string;
  email?: string;
}

interface InviteResult {
  email: string;
  success: boolean;
  error?: string;
}

interface SubscriptionSessionResult {
  monthlySubscription: StripeType.Subscription;
  annualSubscription: StripeType.Subscription;
  monthlyPaymentIntent: StripeType.PaymentIntent;
  annualPaymentIntent: StripeType.PaymentIntent;
  proratedMonthlyAmount: number;
  proratedAnnualAmount: number;
  sessionId: string;
}


// Interface for price IDs
interface PriceIds {
  monthly: string;
  annual: string;
}

// Helper function to get price IDs from the settings table (cached) or from Stripe
async function getPriceIds(): Promise<PriceIds> {
  try {
    // First try to get from settings table (cached values)
    const cachedPrices = await getCachedPriceIds();
    if (cachedPrices) {
      return cachedPrices;
    }
    
    // If not cached or expired, fetch from Stripe
    const freshPrices = await fetchPriceIdsFromStripe();
    
    // Update cache
    await updatePriceCache(freshPrices);
    
    return freshPrices;
  } catch (error) {
    Sentry.captureException(error);
    throw new Error(`Failed to get price IDs: ${error instanceof Error ? error.message : String(error)}`);
  }
}

// Get cached price IDs from the settings table
async function getCachedPriceIds(): Promise<PriceIds | null> {
  try {
    // Get both monthly and annual price IDs in a single query
    const priceData = await db
      .selectFrom('settings')
      .select(['key', 'value', 'updated_at'])
      .where('key', 'in', ['stripe_monthly_price_id', 'stripe_annual_price_id'])
      .execute();
    
    // Extract monthly and annual data from results
    const monthlyData = priceData.find((item) => item.key === 'stripe_monthly_price_id');
    const annualData = priceData.find((item) => item.key === 'stripe_annual_price_id');
    
    // If either data is missing, return null
    if (!monthlyData || !annualData) {
      return null;
    }
    
    // Check if cache is expired (older than 24 hours)
    const monthlyUpdatedAt = dayjs(monthlyData.updated_at);
    const annualUpdatedAt = dayjs(annualData.updated_at);
    const now = dayjs();
    
    if (
      now.diff(monthlyUpdatedAt, 'hour') > 24 ||
      now.diff(annualUpdatedAt, 'hour') > 24
    ) {
      return null;
    }
    
    // Return cached price IDs
    return {
      monthly: monthlyData.value,
      annual: annualData.value
    };
  } catch (error) {
    Sentry.captureException(error);
    return null;
  }
}

// Fetch price IDs directly from Stripe
async function fetchPriceIdsFromStripe(): Promise<PriceIds> {
  // Constants for lookup keys (same as in constants.ts)
  const MEMBERSHIP_FEE_LOOKUP_NAME = Deno.env.get('MEMBERSHIP_FEE_LOOKUP_NAME') ?? 'standard_membership_fee';
  const ANNUAL_FEE_LOOKUP = Deno.env.get('ANNUAL_FEE_LOOKUP') ?? 'annual_membership_fee_revised';
  
  // Fetch prices from Stripe in parallel
  const [monthlyPrices, annualPrices] = await Promise.all([
    stripe.prices.list({
      lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME],
      active: true,
      limit: 1
    }),
    stripe.prices.list({
      lookup_keys: [ANNUAL_FEE_LOOKUP],
      active: true,
      limit: 1
    })
  ]);
  
  // Extract price IDs
  const monthlyPriceId = monthlyPrices.data[0]?.id;
  const annualPriceId = annualPrices.data[0]?.id;
  
  if (!monthlyPriceId || !annualPriceId) {
    throw new Error('Failed to retrieve price IDs from Stripe');
  }
  
  return {
    monthly: monthlyPriceId,
    annual: annualPriceId
  };
}

// Update the price cache in the settings table
async function updatePriceCache(prices: PriceIds): Promise<void> {
  const now = new Date().toISOString();
  
  // Update cache in parallel using kysely transaction
  await db.transaction().execute(async (trx) => {
    await Promise.all([
      trx
        .updateTable('settings')
        .set({
          value: prices.monthly,
          updated_at: now
        })
        .where('key', '=', 'stripe_monthly_price_id')
        .execute(),
      trx
        .updateTable('settings')
        .set({
          value: prices.annual,
          updated_at: now
        })
        .where('key', '=', 'stripe_annual_price_id')
        .execute()
    ]);
  });
}

// Helper function to create a subscription session
async function createSubscriptionSession(userId: string, customerId: string, priceIds: { monthly: string; annual: string }): Promise<SubscriptionSessionResult> {
  try {
    // Create new subscriptions
    const [monthlySubscription, annualSubscription] = await Promise.all([
      stripe.subscriptions.create({
        customer: customerId,
        items: [{ price: priceIds.monthly }],
        billing_cycle_anchor_config: {
          day_of_month: 1
        },
        payment_behavior: 'default_incomplete',
        payment_settings: {
          payment_method_types: ['sepa_debit']
        },
        expand: ['latest_invoice.payment_intent'],
        collection_method: 'charge_automatically'
      }),
      stripe.subscriptions.create({
        customer: customerId,
        items: [{ price: priceIds.annual }],
        payment_behavior: 'default_incomplete',
        payment_settings: {
          payment_method_types: ['sepa_debit']
        },
        billing_cycle_anchor_config: {
          month: 1,
          day_of_month: 7
        },
        expand: ['latest_invoice.payment_intent'],
        collection_method: 'charge_automatically'
      })
    ]);

    const monthlyInvoice = monthlySubscription.latest_invoice as StripeType.Invoice;
    const annualInvoice = annualSubscription.latest_invoice as StripeType.Invoice;
    const monthlyPaymentIntent = monthlyInvoice.payment_intent as StripeType.PaymentIntent;
    const annualPaymentIntent = annualInvoice.payment_intent as StripeType.PaymentIntent;
    const proratedMonthlyAmount = monthlyPaymentIntent.amount;
    const proratedAnnualAmount = annualPaymentIntent.amount;

    // Store the payment session using Kysely
    const sessionId = await createPaymentSession(
      userId,
      customerId,
      monthlySubscription,
      annualSubscription,
      monthlyPaymentIntent,
      annualPaymentIntent,
      db
    );

    return {
      monthlySubscription,
      annualSubscription,
      monthlyPaymentIntent,
      annualPaymentIntent,
      proratedMonthlyAmount,
      proratedAnnualAmount,
      sessionId
    };
  } catch (error) {
    Sentry.captureException(error);
    const errorMessage = error instanceof Error ? error.message : String(error);
    throw new Error(`Error creating subscription session: ${errorMessage}`);
  }
}



// Add event listener for beforeUnload to handle graceful shutdown
addEventListener('beforeunload', (event) => {
  console.log('Function is about to be terminated:', event);
  // Perform any cleanup if needed
});

serve(async (req: Request) => {
  try {
    // Initialize Supabase client with anon key for authentication
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? ''
    );
    
    // Get the authorization header and validate the token
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Missing Authorization header' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      );
    }
    
    const token = authHeader.replace('Bearer ', '');
    const { data: userData, error: authError } = await supabaseClient.auth.getUser(token);
    
    if (authError || !userData?.user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized', details: authError?.message }),
        { status: 403, headers: { 'Content-Type': 'application/json' } }
      );
    }
    
    // Create admin client for privileged operations
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );
    
    // Parse JSON payload from the request
    const { invites } = await req.json() as { invites: InviteData[] };
    
    // Validate user permissions (only admins, presidents, committee coordinators)
    const { data: rolesData } = await supabaseClient.rpc('get_user_roles');
    const userRoles = new Set(rolesData || []);
    
    const ALLOWED_ROLES = new Set(['admin', 'president', 'committee_coordinator']);
    const hasPermission = [...userRoles].some(role => 
      typeof role === 'string' && ALLOWED_ROLES.has(role)
    );
    
    if (!hasPermission) {
      return new Response(
        JSON.stringify({ error: 'Insufficient permissions to create invitations' }),
        { status: 403, headers: { 'Content-Type': 'application/json' } }
      );
    }

    // Get price IDs for immediate validation
    const priceIds = await getPriceIds();
    
    // Create a background task to process invitations
    const processingPromise = processInvitations(invites, userData.user, supabaseAdmin, priceIds);
    
    // Use waitUntil to keep the function running in the background
    EdgeRuntime.waitUntil(processingPromise);
    
    // Return an immediate response to the client
    return new Response(
      JSON.stringify({ 
        message: 'Invitations are being processed in the background', 
        count: invites.length 
      }),
      { headers: { 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    Sentry.captureException(error);
    const errorMessage = error instanceof Error ? error.message : String(error);
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }
});

/**
 * Process invitations in the background
 */
async function processInvitations(
  invites: InviteData[], 
  user: UserData, 
  supabaseAdmin: ReturnType<typeof createClient>,
  priceIds: { monthly: string; annual: string }
) {
  console.log(`Starting background processing of ${invites.length} invitations`);
  const results: InviteResult[] = [];
  const startTime = Date.now();
  
  try {
    // Process each invite
    for (const invite of invites) {
      try {
        // Process the invite in a transaction to ensure atomicity
        await db.transaction().execute(async (trx) => {
          // Calculate unified expiration date (24 hours from now)
          const expiresAt = dayjs().add(24, 'hour').toDate();
          
          // Create a Stripe customer for the invited user
          const customer = await stripe.customers.create({
            name: `${invite.firstName} ${invite.lastName}`,
            email: invite.email,
            metadata: {
              invited_by: user.id
            }
          });
          
          // Invite the user via Supabase Auth
          const { data: authData, error: authError } = await supabaseAdmin.auth.admin.inviteUserByEmail(invite.email, {
            data: {
              first_name: invite.firstName,
              last_name: invite.lastName
            }
          });
          
          if (authError) {
            throw new Error(`Error inviting user: ${authError.message}`);
          }
          
          // Create subscription session
          const subscriptionData = await createSubscriptionSession(
            authData.user.id,
            customer.id,
            priceIds
          );
          
          // Create the invitation record using Kysely
          await createInvitation({
            userId: authData.user.id,
            email: invite.email,
            invitationType: 'admin',
            expiresAt,
            firstName: invite.firstName,
            lastName: invite.lastName,
            dateOfBirth: invite.dateOfBirth,
            phoneNumber: invite.phoneNumber,
            metadata: {
              customerId: customer.id,
              monthlySubscriptionId: subscriptionData.monthlySubscription.id,
              annualSubscriptionId: subscriptionData.annualSubscription.id,
              sessionId: subscriptionData.sessionId
            }
          }, trx);
          
          // Update user profile with customer ID using Kysely
          await updateUserProfileWithCustomerId(authData.user.id, customer.id, trx);
        });
        
        // If we get here, the transaction was successful
        results.push({ 
          email: invite.email, 
          success: true 
        });
        console.log(`Successfully processed invitation for ${invite.email}`);
      } catch (error) {
        Sentry.captureException(error);
        const errorMessage = error instanceof Error ? error.message : String(error);
        results.push({ 
          email: invite.email, 
          success: false, 
          error: errorMessage 
        });
        console.error(`Failed to process invitation for ${invite.email}:`, errorMessage);
      }
    }
    
    // Store the results in a database or send a notification
    await storeProcessingResults(results, user.id);
    
    const processingTime = (Date.now() - startTime) / 1000;
    console.log(`Completed processing ${invites.length} invitations in ${processingTime}s`);
    return results;
  } catch (error) {
    Sentry.captureException(error);
    const errorMessage = error instanceof Error ? error.message : String(error);
    console.error(`Error in background processing: ${errorMessage}`);
    throw error;
  }
}

/**
 * Store the processing results in the database
 */
async function storeProcessingResults(results: InviteResult[], userId: string) {
  try {
    const successCount = results.filter(r => r.success).length;
    const failureCount = results.length - successCount;
    
    // Store the processing summary in the database
    await db.insertInto('invitation_processing_logs')
      .values({
        user_id: userId,
        total_count: results.length,
        success_count: successCount,
        failure_count: failureCount,
        results: JSON.stringify(results),
        created_at: new Date().toISOString()
      })
      .execute();
    
    console.log(`Stored processing results: ${successCount} successful, ${failureCount} failed`);
  } catch (error) {
    Sentry.captureException(error);
    console.error('Failed to store processing results:', error);
  }
}
