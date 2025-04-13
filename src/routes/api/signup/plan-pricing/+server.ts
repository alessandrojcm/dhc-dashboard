import type { RequestHandler } from './$types';
import { jwtDecode } from 'jwt-decode';
import dayjs from 'dayjs';
import { invariant } from '$lib/server/invariant';
import Dinero from 'dinero.js';
import { stripeClient } from '$lib/server/stripe';
import type { PlanPricing } from '$lib/types';
import { getKyselyClient } from '$lib/server/kysely';
import * as Sentry from '@sentry/sveltekit';

export const GET: RequestHandler = async ({ cookies, platform }) => {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
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
			'total_amount',
			'coupon_id',
			'discounted_monthly_amount',
			'discounted_annual_amount',
			'discount_percentage'
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
	// Plan amounts (what user will pay regularly)
	const monthlyAmount = existingSession.monthly_amount;
	const annualAmount = existingSession.annual_amount;

	// Get the payment intent amounts (what user will pay now, including proration and discounts)
	// If total_amount is not available, we need to get the payment intent amounts from Stripe
	let proratedMonthlyAmount = 0;
	let proratedAnnualAmount = 0;
	let totalAmount = existingSession.total_amount;

	if (totalAmount === undefined || totalAmount === null) {
		// If total_amount is not available, try to get the payment intent amounts from Stripe
		try {
			const [monthlyPaymentIntent, annualPaymentIntent] = await Promise.all([
				stripeClient.paymentIntents.retrieve(existingSession.monthly_payment_intent_id),
				stripeClient.paymentIntents.retrieve(existingSession.annual_payment_intent_id)
			]);

			proratedMonthlyAmount = monthlyPaymentIntent.amount;
			proratedAnnualAmount = annualPaymentIntent.amount;
			totalAmount = proratedMonthlyAmount + proratedAnnualAmount;

			// Update the payment_sessions table with the total_amount
			await kysely
				.updateTable('payment_sessions')
				.set({
					total_amount: totalAmount
				})
				.where('user_id', '=', userId)
				.where('monthly_payment_intent_id', '=', existingSession.monthly_payment_intent_id)
				.where('annual_payment_intent_id', '=', existingSession.annual_payment_intent_id)
				.execute();
		} catch (error) {
			Sentry.captureMessage(`Error retrieving payment intents: ${error}`, 'error');
			// Fallback to using the plan amounts
			totalAmount = monthlyAmount + annualAmount;
			proratedMonthlyAmount = monthlyAmount;
			proratedAnnualAmount = annualAmount;
		}
	} else {
		// If we have a total amount but not individual prorated amounts, split it proportionally
		const totalPlanAmount = monthlyAmount + annualAmount;
		if (totalPlanAmount > 0) {
			proratedMonthlyAmount = Math.round((monthlyAmount / totalPlanAmount) * totalAmount);
			proratedAnnualAmount = totalAmount - proratedMonthlyAmount; // Ensure they add up exactly
		}
	}

	// Get discount percentage if available, otherwise calculate it
	let discountPercentage: number | undefined = existingSession.discount_percentage ?? undefined;
	if (
		discountPercentage === undefined &&
		existingSession.discounted_monthly_amount &&
		existingSession.coupon_id
	) {
		// Calculate the discount percentage based on the monthly amount
		const discount = monthlyAmount - existingSession.discounted_monthly_amount;
		discountPercentage = Math.round((discount / monthlyAmount) * 100);
	}

	return Response.json({
		// What the user will pay now (prorated and possibly discounted)
		proratedPrice: Dinero({
			amount: totalAmount,
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
		// What the user will pay regularly (plan amounts)
		monthlyFee: Dinero({
			amount: monthlyAmount,
			currency: 'EUR'
		}).toJSON(),
		annualFee: Dinero({
			amount: annualAmount,
			currency: 'EUR'
		}).toJSON(),
		// Discounted amounts for recurring payments
		...(existingSession.discounted_monthly_amount && {
			discountedMonthlyFee: Dinero({
				amount: existingSession.discounted_monthly_amount,
				currency: 'EUR'
			}).toJSON()
		}),
		...(existingSession.discounted_annual_amount && {
			discountedAnnualFee: Dinero({
				amount: existingSession.discounted_annual_amount,
				currency: 'EUR'
			}).toJSON()
		}),
		// Discount information
		coupon: existingSession?.coupon_id ?? undefined,
		...(discountPercentage !== undefined && { discountPercentage })
	} satisfies PlanPricing);
};
