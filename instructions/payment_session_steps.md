# Payment Session Management Implementation Guide

This guide outlines the steps to implement a payment session management system for the signup process, preventing multiple Stripe invoices when users refresh the page.

## Overview

The current implementation creates new subscriptions and payment intents every time a user loads the signup page. This results in multiple open invoices in Stripe. The solution is to persist payment session information in the database and reuse existing valid payment intents when available.

## Implementation Steps

### 1. ✅ Create Database Migration

Create a new migration file to add the `payment_sessions` table:

```sql
-- Create a new migration file in supabase/migrations/
-- Example: 20250404_add_payment_sessions.sql

-- Create payment_sessions table
CREATE TABLE IF NOT EXISTS public.payment_sessions (
  id SERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id),
  customer_id TEXT NOT NULL,
  monthly_subscription_id TEXT NOT NULL,
  annual_subscription_id TEXT NOT NULL,
  monthly_payment_intent_id TEXT NOT NULL,
  annual_payment_intent_id TEXT NOT NULL,
  monthly_amount INTEGER NOT NULL,
  annual_amount INTEGER NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
  is_used BOOLEAN NOT NULL DEFAULT FALSE
);

-- Add index for faster lookups
CREATE INDEX idx_payment_sessions_user_id ON public.payment_sessions(user_id);

-- Add RLS policies
ALTER TABLE public.payment_sessions ENABLE ROW LEVEL SECURITY;

-- Only service role and the user themselves can access their payment sessions
CREATE POLICY "Users can view their own payment sessions"
  ON public.payment_sessions
  FOR SELECT
  USING (auth.uid() = user_id OR auth.jwt() ->> 'role' = 'service_role');

-- Only service role can insert/update/delete
CREATE POLICY "Service role can manage payment sessions"
  ON public.payment_sessions
  USING (auth.jwt() ->> 'role' = 'service_role');
```

### 2. Update Database Types

Update your Kysely types to include the new table:

```typescript
// src/lib/server/kysely.ts or equivalent

export interface Database {
  // ... existing tables
  
  payment_sessions: {
    id: Generated<number>;
    user_id: string;
    customer_id: string;
    monthly_subscription_id: string;
    annual_subscription_id: string;
    monthly_payment_intent_id: string;
    annual_payment_intent_id: string;
    monthly_amount: number;
    annual_amount: number;
    created_at: Date;
    expires_at: Date;
    is_used: boolean;
  };
}
```

### 3. Modify the Load Function

Update the load function in `src/routes/(public)/members/signup/(signup-form)/+page.server.ts`:

```typescript
export const load: PageServerLoad = async ({ parent, cookies }) => {
  const { userData } = await parent();
  try {
    const invitationData = await kysely.transaction().execute(async (trx) => {
      // Existing invitation validation code...
      
      // Customer ID creation code...
      
      return { ...invitationInfo, customer_id };
    });

    const [subscriptionPrice, annualFeePrice] = await Promise.all([
      // Existing price lookup code...
    ]);

    // Check for an existing valid payment session
    const existingSession = await kysely
      .selectFrom('payment_sessions')
      .select([
        'monthly_subscription_id',
        'annual_subscription_id',
        'monthly_payment_intent_id',
        'annual_payment_intent_id',
        'monthly_amount',
        'annual_amount'
      ])
      .where('user_id', '=', userData.id)
      .where('expires_at', '>', new Date())
      .where('is_used', '=', false)
      .orderBy('created_at', 'desc')
      .executeTakeFirst();

    let monthlyPaymentIntent: Stripe.PaymentIntent;
    let annualPaymentIntent: Stripe.PaymentIntent;
    let proratedMonthlyAmount: number;
    let proratedAnnualAmount: number;
    let monthlySubscription: any;
    let annualSubscription: any;

    if (existingSession) {
      // Retrieve the payment intents to ensure they're still valid
      try {
        [monthlyPaymentIntent, annualPaymentIntent] = await Promise.all([
          stripeClient.paymentIntents.retrieve(existingSession.monthly_payment_intent_id),
          stripeClient.paymentIntents.retrieve(existingSession.annual_payment_intent_id)
        ]);

        // Only use if they're still in a usable state
        if (
          monthlyPaymentIntent.status === 'requires_payment_method' &&
          annualPaymentIntent.status === 'requires_payment_method'
        ) {
          proratedMonthlyAmount = existingSession.monthly_amount;
          proratedAnnualAmount = existingSession.annual_amount;
          
          // Retrieve subscriptions for display purposes
          [monthlySubscription, annualSubscription] = await Promise.all([
            stripeClient.subscriptions.retrieve(existingSession.monthly_subscription_id),
            stripeClient.subscriptions.retrieve(existingSession.annual_subscription_id)
          ]);
        } else {
          // Payment intents are in an unusable state, create new ones
          throw new Error('Payment intents are in an unusable state');
        }
      } catch (error) {
        // If there's any error retrieving or validating, create new ones
        console.error('Error retrieving existing payment session:', error);
        existingSession = null;
      }
    }

    if (!existingSession) {
      // Create new subscriptions as in your current code
      [monthlySubscription, annualSubscription] = await Promise.all([
        stripeClient.subscriptions.create({
          customer: invitationData.customer_id!,
          items: [{ price: subscriptionPrice!.id }],
          billing_cycle_anchor_config: { day_of_month: 1 },
          payment_behavior: 'default_incomplete',
          payment_settings: { payment_method_types: ['sepa_debit'] },
          expand: ['latest_invoice.payment_intent'],
          collection_method: 'charge_automatically'
        }),
        stripeClient.subscriptions.create({
          customer: invitationData.customer_id!,
          items: [{ price: annualFeePrice!.id }],
          payment_behavior: 'default_incomplete',
          payment_settings: { payment_method_types: ['sepa_debit'] },
          billing_cycle_anchor_config: { month: 1, day_of_month: 7 },
          expand: ['latest_invoice.payment_intent'],
          collection_method: 'charge_automatically'
        })
      ]);

      monthlyPaymentIntent = (monthlySubscription.latest_invoice as Stripe.Invoice)!
        .payment_intent as Stripe.PaymentIntent;
      annualPaymentIntent = (annualSubscription.latest_invoice as Stripe.Invoice)!
        .payment_intent as Stripe.PaymentIntent;

      proratedMonthlyAmount = monthlyPaymentIntent.amount;
      proratedAnnualAmount = annualPaymentIntent.amount;

      // Store the new session
      await kysely
        .insertInto('payment_sessions')
        .values({
          user_id: userData.id,
          customer_id: invitationData.customer_id!,
          monthly_subscription_id: monthlySubscription.id,
          annual_subscription_id: annualSubscription.id,
          monthly_payment_intent_id: monthlyPaymentIntent.id,
          annual_payment_intent_id: annualPaymentIntent.id,
          monthly_amount: proratedMonthlyAmount,
          annual_amount: proratedAnnualAmount,
          expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000) // 24 hours
        })
        .execute();
    }

    // Set the cookie with payment info (unchanged)
    cookies.set(
      'stripe-payment-info',
      JSON.stringify({
        customerId: invitationData.customer_id!,
        annualSubscriptionPaymentIntendId: annualPaymentIntent.id,
        membershipSubscriptionPaymentIntendId: monthlyPaymentIntent.id
      } satisfies StripePaymentInfo),
      { path: '/', httpOnly: true, secure: true, sameSite: 'strict' }
    );

    // Return data for the page (unchanged)
    return {
      form: await superValidate({}, valibot(memberSignupSchema), { errors: false }),
      userData: {
        // Existing user data...
      },
      // Rest of the return values remain the same
      proratedPrice: Dinero({
        amount: proratedMonthlyAmount + proratedAnnualAmount,
        currency: 'EUR'
      }).toJSON(),
      proratedMonthlyPrice: Dinero({
        amount: proratedMonthlyAmount,
        currency: 'EUR'
      }).toJSON(),
      proratedAnnualPrice: Dinero({
        amount: proratedAnnualAmount,
        currency: 'EUR'
      }).toJSON(),
      // Other return values...
    };
  } catch (err) {
    console.error(err);
    error(404, {
      message: 'Something went wrong'
    });
  }
};
```

### 4. Update the Default Action

Modify the default action in the same file to mark payment sessions as used after successful payment:

```typescript
export const actions: Actions = {
  default: async (event) => {
    // Existing code...
    
    return kysely
      .transaction()
      .execute(async (trx) => {
        // Existing code for invitation handling and payment processing...
        
        // After successful payment confirmation, mark the session as used
        await trx
          .updateTable('payment_sessions')
          .set({ is_used: true })
          .where('monthly_payment_intent_id', '=', membershipSubscriptionPaymentIntendId)
          .where('annual_payment_intent_id', '=', annualSubscriptionPaymentIntendId)
          .execute();
          
        // Rest of the existing code...
        return message(form, { paymentFailed: false });
      })
      .catch((err) => {
        // Existing error handling...
      });
  }
};
```

### 5. ✅ Create a Cleanup Function

Create a new Edge Function in Supabase to clean up expired payment sessions:

```typescript
// supabase/functions/cleanup-payment-sessions/index.ts

import { createClient } from '@supabase/supabase-js';
import { stripe } from '../_shared/stripe';
import { kysely } from '../_shared/kysely';

// This function should be scheduled to run daily
Deno.serve(async (req) => {
  try {
    // Verify request is authorized (implement your auth check here)
    // ...
    
    const expiredSessions = await kysely
      .selectFrom('payment_sessions')
      .select([
        'id',
        'monthly_subscription_id',
        'annual_subscription_id'
      ])
      .where('expires_at', '<', new Date())
      .where('is_used', '=', false)
      .execute();

    const results = [];
    
    for (const session of expiredSessions) {
      try {
        // Cancel the subscriptions
        await Promise.all([
          stripe.subscriptions.cancel(session.monthly_subscription_id),
          stripe.subscriptions.cancel(session.annual_subscription_id)
        ]);
        
        results.push({
          id: session.id,
          status: 'cancelled'
        });
      } catch (error) {
        console.error(`Error canceling subscriptions for session ${session.id}:`, error);
        results.push({
          id: session.id,
          status: 'error',
          error: error.message
        });
      }
    }

    // Mark all expired sessions as used
    await kysely
      .updateTable('payment_sessions')
      .set({ is_used: true })
      .where('expires_at', '<', new Date())
      .where('is_used', '=', false)
      .execute();

    return new Response(
      JSON.stringify({
        success: true,
        processed: expiredSessions.length,
        results
      }),
      { headers: { 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message
      }),
      { 
        status: 500,
        headers: { 'Content-Type': 'application/json' }
      }
    );
  }
});
```

### 6. ✅ Schedule the Cleanup Function

Set up a scheduled task to run the cleanup function:

1. Deploy the Edge Function to Supabase
2. Create a cron job using Supabase's scheduled functions feature:

```bash
# Using Supabase CLI
supabase functions deploy cleanup-payment-sessions
supabase schedules create cleanup-payment-sessions --cron "0 0 * * *" --function cleanup-payment-sessions
```

Or set up the schedule in the Supabase dashboard under "Edge Functions" > "Schedules".

### 7. Testing

Test the implementation with these scenarios:

1. **New User Flow**: 
   - Verify a new payment session is created on first visit
   - Check database entry is created correctly

2. **Refresh Page Flow**:
   - Load the signup page
   - Refresh the page multiple times
   - Verify only one set of subscriptions is created in Stripe
   - Verify the same payment intents are reused

3. **Expired Session Flow**:
   - Create a session with an expiration date in the past
   - Run the cleanup function
   - Verify the subscriptions are cancelled in Stripe
   - Verify the session is marked as used in the database

4. **Completed Payment Flow**:
   - Complete the signup process with payment
   - Verify the session is marked as used
   - Verify refreshing the page after completion doesn't create new sessions

## Notes and Considerations

1. **Error Handling**: The implementation includes robust error handling to create new sessions if existing ones can't be retrieved or are in an invalid state.

2. **Security**: RLS policies ensure users can only access their own payment sessions.

3. **Expiration**: Sessions expire after 24 hours to prevent stale data.

4. **Cleanup**: The daily cleanup job prevents abandoned subscriptions from accumulating in Stripe.

5. **Proration**: The implementation preserves the original proration amounts to ensure consistent pricing.

6. **Idempotency**: The entire process is designed to be idempotent, allowing for safe retries and page refreshes.

## Troubleshooting

- **Missing Subscriptions**: If subscriptions aren't being reused, check the payment intent status in Stripe.
- **Database Errors**: Verify the migration ran successfully and the table structure matches the expected schema.
- **Stripe API Errors**: Check for rate limiting or authentication issues with the Stripe API.
- **Cleanup Job Failures**: Verify the Edge Function has the necessary permissions to access Stripe and the database.
