import { stripeClient } from '$lib/server/stripe';
import dayjs from 'dayjs';
import type Stripe from 'stripe';
import type { KyselyDatabase, SubscriptionWithPlan } from '$lib/types';
import type { Kysely, Transaction } from 'kysely';
import { getKyselyClient } from './kysely';
import * as Sentry from '@sentry/sveltekit';

/**
 * Creates subscription and payment intents for a user
 * Returns pricing information for the subscription
 */
export async function createSubscriptionSession(
	userId: string,
	customerId: string,
	priceIds: { monthly: string; annual: string },
	kysely: Kysely<KyselyDatabase>
) {
	let monthlyPaymentIntent: Stripe.PaymentIntent | undefined;
	let annualPaymentIntent: Stripe.PaymentIntent | undefined;
	let proratedMonthlyAmount: number = 0;
	let proratedAnnualAmount: number = 0;
	let monthlySubscription: Stripe.Subscription | undefined;
	let annualSubscription: Stripe.Subscription | undefined;

	// Create new subscriptions
	const [newMonthlySubscription, newAnnualSubscription] = await Promise.all([
		stripeClient.subscriptions.create({
			customer: customerId,
			items: [
				{
					price: priceIds.monthly
				}
			],
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
		stripeClient.subscriptions.create({
			customer: customerId,
			items: [
				{
					price: priceIds.annual
				}
			],
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

	monthlySubscription = newMonthlySubscription;
	annualSubscription = newAnnualSubscription;

	const newMonthlyPaymentIntent = (newMonthlySubscription.latest_invoice as Stripe.Invoice)!
		.payment_intent as Stripe.PaymentIntent;
	const newAnnualPaymentIntent = (newAnnualSubscription.latest_invoice as Stripe.Invoice)!
		.payment_intent as Stripe.PaymentIntent;

	monthlyPaymentIntent = newMonthlyPaymentIntent;
	annualPaymentIntent = newAnnualPaymentIntent;
	proratedMonthlyAmount = newMonthlyPaymentIntent.amount;
	proratedAnnualAmount = newAnnualPaymentIntent.amount;

	// Store the new session
	await kysely
		.insertInto('payment_sessions')
		.values({
			user_id: userId,
			monthly_subscription_id: newMonthlySubscription.id,
			annual_subscription_id: newAnnualSubscription.id,
			monthly_payment_intent_id: newMonthlyPaymentIntent.id,
			annual_payment_intent_id: newAnnualPaymentIntent.id,
			// Save the full plan amounts (what user will pay regularly)
			monthly_amount: (monthlySubscription as unknown as SubscriptionWithPlan).plan.amount!,
			annual_amount: (annualSubscription as unknown as SubscriptionWithPlan).plan.amount!,
			// Save the prorated amount (what user will pay now)
			total_amount: proratedMonthlyAmount + proratedAnnualAmount,
			expires_at: dayjs().add(24, 'hour').toISOString()
		})
		.execute();

	return {
		monthlySubscription,
		annualSubscription,
		monthlyPaymentIntent,
		annualPaymentIntent,
		proratedMonthlyAmount,
		proratedAnnualAmount
	};
}

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

/**
 * Validates and retrieves payment intents from an existing session
 */
export async function validateExistingSession(existingSession: ExistingSession) {
	try {
		const [retrievedMonthlyIntent, retrievedAnnualIntent] = await Promise.all([
			stripeClient.paymentIntents.retrieve(existingSession!.monthly_payment_intent_id),
			stripeClient.paymentIntents.retrieve(existingSession!.annual_payment_intent_id)
		]);

		// Only use if they're still in a usable state
		if (
			retrievedMonthlyIntent.status === 'requires_payment_method' &&
			retrievedAnnualIntent.status === 'requires_payment_method'
		) {
			// Retrieve subscriptions for display purposes
			const [retrievedMonthlySubscription, retrievedAnnualSubscription] = await Promise.all([
				stripeClient.subscriptions.retrieve(existingSession!.monthly_subscription_id),
				stripeClient.subscriptions.retrieve(existingSession!.annual_subscription_id)
			]);

			return {
				valid: true,
				monthlyPaymentIntent: retrievedMonthlyIntent,
				annualPaymentIntent: retrievedAnnualIntent,
				proratedMonthlyAmount: retrievedMonthlyIntent.amount,
				proratedAnnualAmount: retrievedAnnualIntent.amount,
				monthlySubscription: retrievedMonthlySubscription,
				annualSubscription: retrievedAnnualSubscription
			};
		} else {
			// Payment intents are in an unusable state
			Sentry.captureMessage(
				`Payment intents are in an unusable state:,
				${retrievedMonthlyIntent.status},
				${retrievedAnnualIntent.status}`,
				'log'
			);
			return { valid: false };
		}
	} catch (error) {
		// If there's any error retrieving or validating, create new ones
		Sentry.captureException(error);
		return { valid: false };
	}
}
