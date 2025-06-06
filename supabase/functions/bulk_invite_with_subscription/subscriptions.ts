import { sql, type QueryExecutorProvider } from 'kysely';
import dayjs from 'dayjs';

/**
 * Interface for payment session result
 */
export interface PaymentSessionResult {
  sessionId: string;
}

/**
 * Creates a payment session record in the database
 * 
 * Modified to only store user_id, coupon_id (optional), and expires_at (7 days)
 * without creating subscriptions or payment intents
 */
export async function createPaymentSession(
  userId: string,
  executor: QueryExecutorProvider,
  couponId?: string
): Promise<string> {
  // Store the new session with minimal data
  const result = await sql<{ id: string }>`
    INSERT INTO payment_sessions (
      user_id,
      coupon_id,
      expires_at
    ) VALUES (
      ${userId}::uuid,
      ${couponId || null}::text,
      ${dayjs().add(7, 'day').toISOString()}::timestamptz
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
