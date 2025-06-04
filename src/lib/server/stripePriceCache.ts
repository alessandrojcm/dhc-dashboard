import { stripeClient } from './stripe';
import { env } from '$env/dynamic/private';
import type { Kysely } from 'kysely';
import type { KyselyDatabase } from '$lib/types';
import { generatePricingInfo } from './pricingUtils';
import type { ExistingSession } from './subscriptionCreation';
import type { PlanPricing, SubscriptionWithPlan } from '$lib/types';
import dayjs from 'dayjs';

export interface PriceIds {
	monthly: string;
	annual: string;
}

/**
 * Fetches price IDs from Stripe based on lookup keys
 * Reused from the Edge function implementation
 */
export async function fetchPriceIds(): Promise<PriceIds> {
	// Constants for lookup keys
	const MEMBERSHIP_FEE_LOOKUP_NAME = 
		env.MEMBERSHIP_FEE_LOOKUP_NAME ?? 'standard_membership_fee';
	const ANNUAL_FEE_LOOKUP = 
		env.ANNUAL_FEE_LOOKUP ?? 'annual_membership_fee_revised';

	// Fetch prices from Stripe in parallel
	const [monthlyPrices, annualPrices] = await Promise.all([
		stripeClient.prices.list({
			lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME],
			active: true,
			limit: 1
		}),
		stripeClient.prices.list({
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

/**
 * Helper function to refresh preview amounts for a payment session
 * This can be used by the plan-pricing endpoint and the coupon endpoint
 */
export async function refreshPreviewAmounts(
	customerId: string, 
	couponId: string | null, 
	db: Kysely<KyselyDatabase>, 
	sessionId: number
): Promise<{
	monthlyAmount: number;
	annualAmount: number;
	proratedMonthlyAmount: number;
	proratedAnnualAmount: number;
	totalAmount: number;
	pricingInfo: PlanPricing;
}> {
	const priceIds = await fetchPriceIds();
	
	// Calculate billing cycle anchors using dayjs
	const currentDate = dayjs();
	
	// For monthly: first day of next month
	const nextMonth = currentDate.add(1, 'month').startOf('month');
	const monthlyBillingAnchor = Math.floor(nextMonth.valueOf() / 1000);
	
	// For annual: January 7th of next year
	const nextYear = currentDate.month() >= 11 ? currentDate.add(1, 'year').year() : currentDate.year() + 1;
	const annualBillingAnchor = Math.floor(dayjs(`${nextYear}-01-07`).valueOf() / 1000);
	
	// Create discounts array if coupon is provided
	const discounts = couponId ? [{ coupon: couponId }] : undefined;
	
	// Preview both monthly and annual subscriptions with proper billing cycle anchors
	const [monthly, annual] = await Promise.all([
		stripeClient.invoices.createPreview({
			customer: customerId,
			currency: 'eur',
			subscription_details: {
				items: [{ price: priceIds.monthly }],
				billing_cycle_anchor: monthlyBillingAnchor
			},
			discounts,
			preview_mode: 'recurring'
		}),
		stripeClient.invoices.createPreview({
			customer: customerId,
			currency: 'eur',
			subscription_details: {
				items: [{ price: priceIds.annual }],
				billing_cycle_anchor: annualBillingAnchor
			},
			discounts,
			preview_mode: 'recurring'
		})
	]);

	// Get the full payment session to pass to generatePricingInfo
	const session = await db
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
		.where(eb => eb('payment_sessions.id', '=', sessionId))
		.executeTakeFirst();

	// Calculate discount percentage if applicable
	let discountPercentage: number | undefined;
	if (couponId && monthly.discounts && monthly.discounts.length > 0 && monthly.subtotal > 0) {
		// Calculate total discount amount from all discounts
		const totalDiscount = monthly.discounts.reduce((sum, discount) => {
				// Handle different types of discount objects
			if (typeof discount === 'object' && discount !== null) {
				const discountAmount = 'amount' in discount && typeof discount.amount === 'number' ? discount.amount : 0;
				return sum + discountAmount;
			}
			return sum;
		}, 0);
		discountPercentage = Math.round((totalDiscount / monthly.subtotal) * 100);
	}
	
	// Get the annual price to calculate prorations
	// We don't need monthly price as we're using the invoice preview amount
	const annualPrice = await stripeClient.prices.retrieve(priceIds.annual);
	
	// Calculate manual proration for monthly subscription
	// For monthly: prorate based on days remaining in current month
	const daysInMonth = currentDate.daysInMonth();
	const daysRemaining = daysInMonth - currentDate.date() + 1; // +1 to include current day
	const dailyRate = monthly.amount_due / daysInMonth;
	const proratedMonthlyAmount = Math.round(dailyRate * daysRemaining);
	
	// For annual fee, we charge the full amount as it's a one-time yearly fee
	const proratedAnnualAmount = annualPrice.unit_amount || 0;
	
	// Apply discount to prorated amounts if applicable
	const discountedProratedMonthlyAmount = discountPercentage 
		? Math.round(proratedMonthlyAmount * (100 - discountPercentage) / 100) 
		: proratedMonthlyAmount;
	
	const discountedProratedAnnualAmount = discountPercentage 
		? Math.round(proratedAnnualAmount * (100 - discountPercentage) / 100) 
		: proratedAnnualAmount;

	// Update payment session with preview amounts and prorated amounts
	// Note: The prorated amount columns need to be added to the database schema
	// via the migration file we created
	await db.updateTable('payment_sessions')
		.set({ 
			preview_monthly_amount: monthly.amount_due, 
			preview_annual_amount: annual.amount_due,
			// We're assuming these columns exist after applying the migration
			// If they don't exist yet, comment these lines out until migration is applied
			// prorated_monthly_amount: discountedProratedMonthlyAmount,
			// prorated_annual_amount: discountedProratedAnnualAmount,
			...(discountPercentage ? { discount_percentage: discountPercentage } : {})
		})
		.where(eb => eb('id', '=', sessionId))
		.execute();

	// Create mock subscription objects for pricing info generation
	const monthlySubscription = {
		plan: {
			amount: session?.monthly_amount || monthly.amount_due
		}
	};

	const annualSubscription = {
		plan: {
			amount: session?.annual_amount || annual.amount_due
		}
	};

	// Create an existing session object for pricing info generation
	const existingSession: ExistingSession = {
		monthly_subscription_id: session?.monthly_subscription_id || null,
		annual_subscription_id: session?.annual_subscription_id || null,
		monthly_payment_intent_id: session?.monthly_payment_intent_id || null,
		annual_payment_intent_id: session?.annual_payment_intent_id || null,
		monthly_amount: session?.monthly_amount || monthly.amount_due,
		annual_amount: session?.annual_amount || annual.amount_due,
		coupon_id: couponId,
		total_amount: discountedProratedMonthlyAmount + discountedProratedAnnualAmount,
		discounted_monthly_amount: session?.discounted_monthly_amount || null,
		discounted_annual_amount: session?.discounted_annual_amount || null,
		discount_percentage: discountPercentage || session?.discount_percentage || null,
		customer_id: session?.customer_id || customerId
	};

	// Generate pricing info for frontend with all required parameters
	const pricingInfo = generatePricingInfo(
		monthlySubscription as unknown as SubscriptionWithPlan,
		annualSubscription as unknown as SubscriptionWithPlan,
		discountedProratedMonthlyAmount,
		discountedProratedAnnualAmount,
		existingSession
	);

	return {
		monthlyAmount: monthly.amount_due,
		annualAmount: annual.amount_due,
		proratedMonthlyAmount: discountedProratedMonthlyAmount,
		proratedAnnualAmount: discountedProratedAnnualAmount,
		totalAmount: monthly.amount_due + annual.amount_due,
		pricingInfo
	};
}
