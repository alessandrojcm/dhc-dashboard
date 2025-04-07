import type { RequestHandler } from './$types';
import { jwtDecode } from 'jwt-decode';
import dayjs from 'dayjs';
import { invariant } from '$lib/server/invariant';
import Dinero from 'dinero.js';
import { stripeClient } from '$lib/server/stripe';
import { kysely } from '$lib/server/kysely';
import type Stripe from 'stripe';
import type { PlanPricing, SubscriptionWithPlan } from '$lib/types';

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
			'annual_amount'
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

	const [annualMembership, monthlyFee] = await Promise.all([
		stripeClient.subscriptions.retrieve(existingSession.annual_subscription_id!, {
			expand: ['latest_invoice.payment_intent']
		}),
		stripeClient.subscriptions.retrieve(existingSession.monthly_subscription_id!, {
			expand: ['latest_invoice.payment_intent']
		})
	]);

	const monthlyPaymentIntent = (monthlyFee.latest_invoice as Stripe.Invoice)!
		.payment_intent as Stripe.PaymentIntent;
	const annualPaymentIntent = (annualMembership.latest_invoice as Stripe.Invoice)!
		.payment_intent as Stripe.PaymentIntent;

	return Response.json({
		proratedPrice: Dinero({
			amount: monthlyPaymentIntent.amount + annualPaymentIntent.amount,
			currency: 'EUR'
		}).toJSON(),
		proratedMonthlyPrice: Dinero({
			amount: monthlyPaymentIntent.amount,
			currency: 'EUR'
		}).toJSON(),
		proratedAnnualPrice: Dinero({
			amount: annualPaymentIntent.amount,
			currency: 'EUR'
		}).toJSON(),
		monthlyFee: Dinero({
			amount: (monthlyFee as unknown as SubscriptionWithPlan).plan.amount!,
			currency: 'EUR'
		}).toJSON(),
		annualFee: Dinero({
			amount: (annualMembership as unknown as SubscriptionWithPlan).plan.amount!,
			currency: 'EUR'
		}).toJSON()
	} satisfies PlanPricing);
};
