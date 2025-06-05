import { error, json, type RequestHandler } from "@sveltejs/kit";
import { getKyselyClient } from "$lib/server/kysely";
import { refreshPreviewAmounts } from "$lib/server/stripePriceCache";
import { generatePricingInfo } from "$lib/server/pricingUtils";
import type { SubscriptionWithPlan, PlanPricing } from "$lib/types";
import * as Sentry from "@sentry/sveltekit";
import { stripeClient } from "$lib/server/stripe";
import { env } from "$env/dynamic/private";
import {
	ANNUAL_FEE_LOOKUP,
	MEMBERSHIP_FEE_LOOKUP_NAME,
} from "$lib/server/constants";
import dayjs from "dayjs";
import isSameOrAfter from "dayjs/plugin/isSameOrAfter";
dayjs.extend(isSameOrAfter);
import * as v from "valibot";

// Special migration code constant
const DASHBOARD_MIGRATION_CODE = env.PUBLIC_DASHBOARD_MIGRATION_CODE ??
	"DHCDASHBOARD";

const couponCodeSchema = v.object({
	code: v.string()
});

async function getPricingDetails(
	userId: string,
	kysely: ReturnType<typeof getKyselyClient>,
	paymentSessionId: number,
	couponCode?: string
) {
	// Fetch base Stripe prices
	const prices = await stripeClient.prices.list({
		lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME, ANNUAL_FEE_LOOKUP],
		active: true,
		limit: 2,
	});

	const monthlyPrice = prices.data.find(p => p.lookup_key === MEMBERSHIP_FEE_LOOKUP_NAME);
	const annualPrice = prices.data.find(p => p.lookup_key === ANNUAL_FEE_LOOKUP);

	if (!monthlyPrice || !annualPrice) {
		Sentry.captureMessage("Base prices not found for membership products", {
			extra: { userId, paymentSessionId },
		});
		throw error(500, "Could not retrieve base product prices.");
	}

	// Get user profile for customer ID
	const userProfile = await kysely
		.selectFrom("user_profiles")
		.select(["customer_id"])
		.where("supabase_user_id", "=", userId)
		.executeTakeFirst();

	if (!userProfile?.customer_id) {
		throw error(500, "User profile or Stripe customer ID not found");
	}

	const customerId = userProfile.customer_id;
	const nextMonth = dayjs().add(1, 'month').startOf('month').unix();
	const nextJanuary = dayjs().month(0).date(7).add(1, 'year').unix();
	try {
		// Get invoice previews for initial payment, next month, and next January
		const [initialInvoiceMonthly, initialInvoiceAnnual, nextMonthInvoice, nextJanuaryInvoice] = await Promise.all([
			stripeClient.invoices.createPreview({
				customer: customerId,
				subscription_details: {
					items: [
						{
							price: monthlyPrice.id,
							quantity: 1
						}
					],
					billing_cycle_anchor: nextMonth
				},
				...(couponCode ? { discounts: [{ promotion_code: couponCode }] } : {})
			}),
			stripeClient.invoices.createPreview({
				customer: customerId,
				subscription_details: {
					items: [
						{
							price: annualPrice.id,
							quantity: 1
						}
					],
					billing_cycle_anchor: nextJanuary
				},
				...(couponCode ? { discounts: [{ promotion_code: couponCode }] } : {})
			}),
			stripeClient.invoices.createPreview({
				customer: customerId,
				subscription_details: {
					items: [
						{
							price: monthlyPrice.id,
							quantity: 1
						}
					],
					start_date: nextMonth
				},
				...(couponCode ? { discounts: [{ promotion_code: couponCode }] } : {})
			}),
			stripeClient.invoices.createPreview({
				customer: customerId,
				subscription_details: {
					items: [
						{
							price: annualPrice.id,
							quantity: 1
						}
					],
					start_date: nextJanuary
				},
				...(couponCode ? { discounts: [{ promotion_code: couponCode }] } : {})
			})
		]);
		// Calculate total discount and discount percentage
		const totalDiscount = initialInvoiceMonthly.total_discount_amounts?.reduce((sum, discount) => sum + discount.amount, 0) ?? 0;
		const discountPercentage = totalDiscount > 0 ? Math.round((totalDiscount / initialInvoiceMonthly.subtotal) * 100) : 0;

		// Update payment session with new invoice details
		await kysely
			.updateTable("payment_sessions")
			.set({
				monthly_amount: initialInvoiceMonthly.amount_due,
				annual_amount: nextJanuaryInvoice.amount_due,
				preview_monthly_amount: nextMonthInvoice.amount_due,
				preview_annual_amount: nextJanuaryInvoice.amount_due,
				discount_percentage: discountPercentage,
				total_amount: initialInvoiceMonthly.amount_due,
				discounted_monthly_amount: initialInvoiceMonthly.amount_due,
				discounted_annual_amount: nextJanuaryInvoice.amount_due
			})
			.where("id", "=", paymentSessionId)
			.execute();

			const monthlyDiscount = nextMonthInvoice?.total_discount_amounts?.reduce((sum, discount) => sum + discount.amount, 0) ?? 0;
			const annualDiscount = nextJanuaryInvoice?.total_discount_amounts?.reduce((sum, discount) => sum + discount.amount, 0) ?? 0;

		return {
			proratedPrice: initialInvoiceMonthly.amount_due + initialInvoiceAnnual.amount_due,
			monthlyFee: nextMonthInvoice.amount_due,
			annualFee: nextJanuaryInvoice.amount_due,
			discountPercentage,
			coupon: couponCode,
			discountedMonthlyFee: monthlyDiscount > 0 ? nextMonthInvoice.amount_due - monthlyDiscount : 0,
			discountedAnnualFee: annualDiscount > 0 ? nextJanuaryInvoice.amount_due - annualDiscount : 0
		}
	} catch (err) {
		console.error(err);
		Sentry.captureException(err);
		throw error(500, "Failed to get pricing details");
	}
}


async function getPaymentSession(
	userId: string,
	kysely: ReturnType<typeof getKyselyClient>,
) {
	return kysely
		.selectFrom("payment_sessions")
		.select([
			"payment_sessions.id",
			"coupon_id",
			"monthly_amount",
			"annual_amount",
			"preview_monthly_amount",
			"preview_annual_amount",
			"discount_percentage",
			"monthly_subscription_id",
			"annual_subscription_id",
			"monthly_payment_intent_id",
			"annual_payment_intent_id",
			"total_amount",
			"discounted_monthly_amount",
			"discounted_annual_amount",
		])
		.leftJoin(
			"user_profiles",
			"user_profiles.supabase_user_id",
			"payment_sessions.user_id",
		)
		.select(["customer_id"])
		.where((eb) => eb("payment_sessions.user_id", "=", userId))
		.where((eb) => eb("payment_sessions.is_used", "=", false))
		.where((eb) =>
			eb("payment_sessions.expires_at", ">", dayjs().toISOString())
		)
		.executeTakeFirst();
}

export const POST: RequestHandler = async ({ request, params, platform }) => {
	try {
		const { invitationId } = params;
		if (!invitationId) {
			throw error(400, "Missing invitation ID");
		}
		const kysely = getKyselyClient(platform?.env?.HYPERDRIVE);

		// 1. Fetch invitation to get user_id
		const invitation = await kysely
			.selectFrom("invitations")
			.select(["user_id"])
			.where("id", "=", invitationId)
			.where("status", "=", "pending")
			.where("expires_at", ">", dayjs().toISOString())
			.executeTakeFirst();

		if (!invitation) {
			throw error(404, "Invitation not found");
		}

		const body = await request.json();
		const couponCode = v.safeParse(couponCodeSchema, body);
		if (!couponCode.success) {
			Sentry.captureMessage("Invalid coupon code", {
				extra: {
					invitationId,
					body,
					couponCode: couponCode.issues
				}
			});
			throw error(400, "Invalid coupon code");
		}

		// Get payment session
		const paymentSession = await getPaymentSession(invitation.user_id!, kysely);
		if (!paymentSession) {
			throw error(404, "Payment session not found");
		}

		// Handle no coupon code
		if (!couponCode) {
			const pricingInfo = await getPricingDetails(
				invitation.user_id!,
				kysely,
				paymentSession.id!
			);
			return json(pricingInfo);
		}

		// Validate promotion code with Stripe
		const promotionCodes = await stripeClient.promotionCodes.list({
			active: true,
			code: couponCode.output.code,
			limit: 1,
		});

		if (!promotionCodes.data.length) {
			throw error(400, "Invalid or inactive promotion code");
		}

		// Handle migration code
		if (couponCode.output.code === DASHBOARD_MIGRATION_CODE.toLowerCase()) {
			const pricingInfo = await getPricingDetails(
				invitation.user_id!,
				kysely,
				paymentSession.id!
			);

			// Override with migration pricing (proration = 0)
			const migrationPricing = {
				...pricingInfo,
				proratedPrice: 0,
				discountPercentage: 100,
				code: couponCode,
			};

			// Save migration code in DB
			await kysely.updateTable("payment_sessions")
				.set({ coupon_id: couponCode.output.code, total_amount: 0, discount_percentage: 100 })
				.where("id", "=", paymentSession.id)
				.execute();

			return json(generatePricingInfo(migrationPricing));
		}


		const couponDetails = await stripeClient.coupons.retrieve(promotionCodes.data[0].coupon.id, {
			expand: ['applies_to']
		});

		// Check if coupon type is supported
		if (couponDetails.duration === 'forever' && couponDetails.amount_off) {
			throw error(400, "Forever coupons can only be percentage-based, not amount-based");
		}

		// Calculate discount percentage for DB storage
		let discountPercentage = 0;
		if (couponDetails.percent_off) {
			discountPercentage = couponDetails.percent_off;
		} else if (couponDetails.amount_off && couponDetails.duration === 'once') {
			// Approximate percentage for one-time amount discounts
			const totalAmount = (paymentSession.monthly_amount || 0) + (paymentSession.annual_amount || 0);
			if (totalAmount > 0) {
				discountPercentage = Math.round((couponDetails.amount_off / totalAmount) * 100);
			}
		}

		// Get pricing with discount applied
		const pricingInfo = await getPricingDetails(
			invitation.user_id!,
			kysely,
			paymentSession.id!,
			promotionCodes.data[0].id
		);

		// Save coupon in DB
		await kysely.updateTable("payment_sessions")
			.set({ coupon_id: couponCode.output.code, discount_percentage: discountPercentage })
			.where("id", "=", paymentSession.id)
			.execute();

		return json(generatePricingInfo(pricingInfo));
	} catch (err) {
		console.error(err);
		Sentry.captureException(err);
		if (err instanceof v.ValiError) {
			throw error(400, "Invalid request body");
		}
		throw error(500, "Failed to get pricing details");
	}
};

export const GET: RequestHandler = async ({ params, platform }) => {
	try {
		const { invitationId } = params;
		if (!invitationId) {
			throw error(400, "Missing invitation ID");
		}
		const kysely = getKyselyClient(platform?.env?.HYPERDRIVE);

		// 1. Fetch invitation to get user_id
		const invitation = await kysely
			.selectFrom("invitations")
			.select(["user_id"])
			.where("id", "=", invitationId)
			.where("status", "=", "pending")
			.where("expires_at", ">", dayjs().toISOString()) // Consider re-adding if needed for stricter validation
			.executeTakeFirst();

		if (!invitation) {
			throw error(404, "Invitation not found");
		}


		// Get payment session
		const paymentSession = await getPaymentSession(invitation.user_id!, kysely);
		if (!paymentSession) {
			throw error(404, "Payment session not found");
		}

		const pricingInfo = await getPricingDetails(
			invitation.user_id!,
			kysely,
			paymentSession.id!,
		);

		return json(generatePricingInfo(pricingInfo));
	} catch (err) {
		Sentry.captureException(err);
		throw error(500, "Failed to get pricing details");
	}
};
