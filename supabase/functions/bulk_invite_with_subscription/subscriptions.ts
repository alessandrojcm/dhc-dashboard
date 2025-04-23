import { sql, type QueryExecutorProvider } from 'kysely';
import type { Stripe } from 'stripe';
import dayjs from 'dayjs';

/**
 * Interface for subscription session result
 */
export interface SubscriptionSessionResult {
  monthlySubscription: Stripe.Subscription;
  annualSubscription: Stripe.Subscription;
  monthlyPaymentIntent: Stripe.PaymentIntent;
  annualPaymentIntent: Stripe.PaymentIntent;
  monthlyAmount: number;
  annualAmount: number;
  sessionId: string;
}

/**
 * Creates a payment session record in the database
 */
export async function createPaymentSession(
  userId: string,
  monthlySubscription: Stripe.Subscription,
  annualSubscription: Stripe.Subscription,
  monthlyPaymentIntentId: string,
  annualPaymentIntentId: string,
  monthlyAmount: number,
  annualAmount: number,
  totalAmount: number,
  executor: QueryExecutorProvider
): Promise<string> {
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
      ${monthlyPaymentIntentId}::text,
      ${annualPaymentIntentId}::text,
      ${monthlyAmount}::integer,
      ${annualAmount}::integer,
      ${totalAmount}::integer,
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
