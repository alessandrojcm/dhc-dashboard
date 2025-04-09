import type { RequestHandler } from './$types';
import { jwtDecode } from 'jwt-decode';
import dayjs from 'dayjs';
import { invariant } from '$lib/server/invariant';
import Dinero from 'dinero.js';
import { kysely } from '$lib/server/kysely';
import type { PlanPricing } from '$lib/types';

export const GET: RequestHandler = async ({ cookies }) => {
	const accessToken = cookies.get('access-token');
	invariant(accessToken === null, 'There has been an error with your signup.');
	const tokenClaim = jwtDecode(accessToken!);
	invariant(dayjs.unix(tokenClaim.exp!).isBefore(dayjs()), 'This invitation has expired');
	const userId = tokenClaim.sub!;

	const existingSession = await kysely
		.selectFrom('payment_sessions')
		.select([
			'monthly_subscription_id',
			'annual_subscription_id',
			'monthly_payment_intent_id',
			'annual_payment_intent_id',
			'monthly_amount',
			'annual_amount',
			'coupon_id'
		])
		.where('user_id', '=', userId)
		.where('expires_at', '>', dayjs().toISOString())
		.where('is_used', '=', false)
		.leftJoin('user_profiles', 'user_profiles.supabase_user_id', 'payment_sessions.user_id')
		.select(['customer_id'])
		.executeTakeFirst();
	if (!existingSession) {
		return Response.json(
			{ message: 'No payment session found for this user.' },
			{
				status: 404
			}
		);
	}

	// Use the values stored in the database instead of making API calls to Stripe
	const monthlyAmount = existingSession.monthly_amount;
	const annualAmount = existingSession.annual_amount;

	return Response.json({
		proratedPrice: Dinero({
			amount: monthlyAmount + annualAmount,
			currency: 'EUR'
		}).toJSON(),
		proratedMonthlyPrice: Dinero({
			amount: monthlyAmount,
			currency: 'EUR'
		}).toJSON(),
		proratedAnnualPrice: Dinero({
			amount: annualAmount,
			currency: 'EUR'
		}).toJSON(),
		monthlyFee: Dinero({
			amount: monthlyAmount,
			currency: 'EUR'
		}).toJSON(),
		annualFee: Dinero({
			amount: annualAmount,
			currency: 'EUR'
		}).toJSON(),
		coupon: existingSession?.coupon_id ?? undefined
	} satisfies PlanPricing);
};
