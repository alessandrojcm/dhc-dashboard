import { sql, type QueryExecutorProvider } from 'https://esm.sh/kysely@0.23.4';
import type { Stripe } from 'https://esm.sh/stripe@12.4.0?target=deno';
import dayjs from 'https://esm.sh/dayjs@1.11.7';

/**
 * Interface for subscription session result
 */
export interface SubscriptionSessionResult {
  monthlySubscription: Stripe.Subscription;
  annualSubscription: Stripe.Subscription;
  monthlyPaymentIntent: Stripe.PaymentIntent;
  annualPaymentIntent: Stripe.PaymentIntent;
  proratedMonthlyAmount: number;
  proratedAnnualAmount: number;
  sessionId: string;
}

/**
 * Creates a payment session record in the database
 */
export async function createPaymentSession(
  userId: string,
  customerId: string,
  monthlySubscription: Stripe.Subscription,
  annualSubscription: Stripe.Subscription,
  monthlyPaymentIntent: Stripe.PaymentIntent,
  annualPaymentIntent: Stripe.PaymentIntent,
  executor: QueryExecutorProvider
): Promise<string> {
  const monthlyAmount = monthlySubscription.items.data[0]?.price?.unit_amount || 0;
  const annualAmount = annualSubscription.items.data[0]?.price?.unit_amount || 0;
  const proratedMonthlyAmount = monthlyPaymentIntent.amount;
  const proratedAnnualAmount = annualPaymentIntent.amount;
  
  // Store the new session
  const result = await sql<{ id: string }>`
    INSERT INTO payment_sessions (
      user_id,
      monthly_subscription_id,
      annual_subscription_id,
      monthly_payment_intent_id,
      annual_payment_intent_id,
      monthly_amount,
      annual_amount,
      total_amount,
      expires_at
    ) VALUES (
      ${userId}::uuid,
      ${monthlySubscription.id}::text,
      ${annualSubscription.id}::text,
      ${monthlyPaymentIntent.id}::text,
      ${annualPaymentIntent.id}::text,
      ${monthlyAmount}::integer,
      ${annualAmount}::integer,
      ${proratedMonthlyAmount + proratedAnnualAmount}::integer,
      ${dayjs().add(24, 'hour').toISOString()}::timestamptz
    )
    RETURNING id
  `.execute(executor);
  
  return result.rows[0]?.id;
}

/**
 * Updates a user profile with a customer ID
 */
export async function updateUserProfileWithCustomerId(
  userId: string,
  customerId: string,
  executor: QueryExecutorProvider
): Promise<void> {
  await sql`
    UPDATE user_profiles
    SET customer_id = ${customerId}::text
    WHERE supabase_user_id = ${userId}::uuid
  `.execute(executor);
}
