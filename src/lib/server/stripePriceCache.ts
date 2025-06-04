import { stripeClient } from "./stripe";
import { env } from "$env/dynamic/private";
import type { Kysely } from "kysely";
import type { KyselyDatabase } from "$lib/types";
import dayjs from "dayjs";
import isLeapYear from "dayjs/plugin/isLeapYear";
import dayOfYear from "dayjs/plugin/dayOfYear";

// Extend dayjs with plugins
dayjs.extend(isLeapYear);
dayjs.extend(dayOfYear);

export interface PriceIds {
	monthly: string;
	monthlyAmount: number;
	annual: string;
	annualAmount: number;
}

/**
 * Fetches price IDs from Stripe based on lookup keys
 * Reused from the Edge function implementation
 */
export async function fetchPriceIds(): Promise<PriceIds> {
	// Constants for lookup keys
	const MEMBERSHIP_FEE_LOOKUP_NAME = env.MEMBERSHIP_FEE_LOOKUP_NAME ??
		"standard_membership_fee";
	const ANNUAL_FEE_LOOKUP = env.ANNUAL_FEE_LOOKUP ??
		"annual_membership_fee_revised";

	// Fetch prices from Stripe in parallel
	const [monthlyPrices, annualPrices] = await Promise.all([
		stripeClient.prices.list({
			lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME],
			active: true,
			limit: 1,
		}),
		stripeClient.prices.list({
			lookup_keys: [ANNUAL_FEE_LOOKUP],
			active: true,
			limit: 1,
		}),
	]);

	// Extract price IDs
	const monthlyPriceId = monthlyPrices.data[0]?.id;
	const annualPriceId = annualPrices.data[0]?.id;

	if (!monthlyPriceId || !annualPriceId) {
		throw new Error("Failed to retrieve price IDs from Stripe");
	}

	return {
		monthly: monthlyPriceId,
		monthlyAmount: monthlyPrices.data[0]?.unit_amount as number,
		annual: annualPriceId,
		annualAmount: annualPrices.data[0]?.unit_amount as number,
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
	sessionId: number,
): Promise<{
	monthlyAmount: number;
	annualAmount: number;
	proratedMonthlyAmount: number;
	proratedAnnualAmount: number;
	totalAmount: number;
}> {
	const priceIds = await fetchPriceIds();

	// Calculate billing cycle anchors using dayjs
	const currentDate = dayjs();

	// For monthly: first day of next month
	const monthlyBillingAnchor = currentDate.add(1, "month").startOf("month")
		.unix();
	// For annual: January 7th of next year
	const annualBillingAnchor = currentDate.add(1, "year").set("month", 0).set(
		"day",
		7,
	).unix();

	// Create discounts array if coupon is provided
	const discounts = couponId ? [{ coupon: couponId }] : undefined;

	// Preview both monthly and annual subscriptions with proper billing cycle anchors
	const [monthly, annual] = await Promise.all([
		stripeClient.invoices.createPreview({
			customer: customerId,
			currency: "eur",
			subscription_details: {
				items: [{ price: priceIds.monthly }],
				billing_cycle_anchor: monthlyBillingAnchor,
			},
			discounts,
			preview_mode: "recurring",
		}),
		stripeClient.invoices.createPreview({
			customer: customerId,
			currency: "eur",
			subscription_details: {
				items: [{ price: priceIds.annual }],
				billing_cycle_anchor: annualBillingAnchor,
			},
			discounts,
			preview_mode: "recurring",
		}),
	]);

	// Get the full payment session to pass to generatePricingInfo
	const session = await db
		.selectFrom("payment_sessions")
		.select([
			"monthly_subscription_id",
			"annual_subscription_id",
			"monthly_payment_intent_id",
			"annual_payment_intent_id",
			"monthly_amount",
			"annual_amount",
			"coupon_id",
			"total_amount",
			"discounted_monthly_amount",
			"discounted_annual_amount",
			"discount_percentage",
		])
		.leftJoin(
			"user_profiles",
			"user_profiles.supabase_user_id",
			"payment_sessions.user_id",
		)
		.select(["customer_id"])
		.where((eb) => eb("payment_sessions.id", "=", sessionId))
		.executeTakeFirst();

	// Calculate discount percentage if applicable
	let discountPercentage: number | undefined;
	if (
		couponId && monthly.discounts && monthly.discounts.length > 0 &&
		monthly.subtotal > 0
	) {
		// Calculate total discount amount from all discounts
		const totalDiscount = monthly.discounts.reduce((sum, discount) => {
			// Handle different types of discount objects
			if (typeof discount === "object" && discount !== null) {
				const discountAmount =
					"amount" in discount && typeof discount.amount === "number"
						? discount.amount
						: 0;
				return sum + discountAmount;
			}
			return sum;
		}, 0);
		discountPercentage = Math.round(
			(totalDiscount / monthly.subtotal) * 100,
		);
	}

	// Update payment session with preview amounts and prorated amounts
	// Note: The prorated amount columns need to be added to the database schema
	// via the migration file we created
	await db.updateTable("payment_sessions")
		.set({
			preview_monthly_amount: monthly.amount_due,
			preview_annual_amount: annual.amount_due,
			// We're assuming these columns exist after applying the migration
			// If they don't exist yet, comment these lines out until migration is applied
			prorated_monthly_amount: monthly.amount_due,
			prorated_annual_amount: annual.amount_due,
			monthly_amount: priceIds.monthlyAmount,
			annual_amount: priceIds.annualAmount,
			...(discountPercentage
				? { discount_percentage: discountPercentage }
				: {}),
		})
		.where((eb) => eb("id", "=", sessionId))
		.execute();

	return {
		monthlyAmount: priceIds.monthlyAmount,
		annualAmount: priceIds.annualAmount,
		proratedMonthlyAmount: monthly.amount_due,
		proratedAnnualAmount: annual.amount_due,
		totalAmount: monthly.amount_due + annual.amount_due,
	};
}
