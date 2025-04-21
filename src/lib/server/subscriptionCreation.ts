import dayjs from 'dayjs';
import type { KyselyDatabase } from '$lib/types';
import type { Kysely, Transaction } from 'kysely';

/**
 * Retrieves an existing payment session for a user
 */
export async function getExistingPaymentSession(
	userId: string,
	client: Transaction<KyselyDatabase> | Kysely<KyselyDatabase>
) {
	return client
		.selectFrom('payment_sessions')
		.select([
			'monthly_subscription_id',
			'annual_subscription_id',
			'monthly_payment_intent_id',
			'annual_payment_intent_id',
			'monthly_amount',
			'annual_amount',
			'coupon_id',
			'total_amount',
			'discounted_monthly_amount',
			'discounted_annual_amount',
			'discount_percentage'
		])
		.leftJoin('user_profiles', 'user_profiles.supabase_user_id', 'payment_sessions.user_id')
		.select(['customer_id'])
		.where('user_id', '=', userId)
		.where('expires_at', '>', dayjs().toISOString())
		.where('is_used', '=', false)
		.orderBy('payment_sessions.created_at', 'desc')
		.executeTakeFirst();
}
export type ExistingSession = Awaited<ReturnType<typeof getExistingPaymentSession>>;