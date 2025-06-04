import type { RequestHandler } from "@sveltejs/kit";
import { getKyselyClient } from "$lib/server/kysely";
import { error } from "@sveltejs/kit";
import { refreshPreviewAmounts } from "$lib/server/stripePriceCache";
import { generatePricingInfo } from "$lib/server/pricingUtils";
import type { SubscriptionWithPlan } from "$lib/types";
import * as Sentry from "@sentry/sveltekit";
import { stripeClient } from "$lib/server/stripe";
import { env } from "$env/dynamic/public";
import dayjs from "dayjs";
import * as v from "valibot";

// Special migration code constant
const DASHBOARD_MIGRATION_CODE = env.PUBLIC_DASHBOARD_MIGRATION_CODE ??
	"DHCDASHBOARD";

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

/**
 * Consolidated endpoint for plan pricing and invoice preview
 * Handles both basic pricing information and detailed invoice preview with proration and discounts
 */
export const GET: RequestHandler = async ({ params, platform = {}, url }) => {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);

	// Get invitation and user data
	const invitation = await kysely
		.selectFrom("invitations")
		.select(["user_id", "id"])
		.where((eb) => eb("id", "=", params?.invitationId || ""))
		.where((eb) => eb("status", "=", "pending"))
		.executeTakeFirst();

	if (!invitation || !invitation.user_id) {
		throw error(404, "Invalid invitation");
	}

	// Get payment session data with all necessary fields
	const paymentSession = await getPaymentSession(invitation.user_id, kysely);

	if (!paymentSession || !paymentSession.customer_id) {
		throw error(404, "Invalid payment session");
	}

	// Check if we should force refresh the preview amounts
	const forceRefresh = url.searchParams.get("refresh") === "true";
	const isValidSession = [
		paymentSession.annual_amount,
		paymentSession.monthly_amount,
		paymentSession.total_amount,
		paymentSession.preview_annual_amount,
		paymentSession.preview_monthly_amount,
	].every(Boolean);

	// If we have preview amounts and we're not forcing a refresh, use the existing data
	if (
		!forceRefresh &&
		isValidSession
	) {
		// Create the pricing info directly from the payment session data
		const monthlySubscription = {
			plan: { amount: paymentSession.monthly_amount },
		} as unknown as SubscriptionWithPlan;

		const annualSubscription = {
			plan: { amount: paymentSession.annual_amount },
		} as unknown as SubscriptionWithPlan;

		// Calculate prorated amounts manually until migration is applied
		// In the future, these will come from the database
		const proratedMonthlyAmount = 0; // Will be populated by migration
		const proratedAnnualAmount = 0; // Will be populated by migration

		return Response.json(generatePricingInfo(
			monthlySubscription,
			annualSubscription,
			proratedMonthlyAmount,
			proratedAnnualAmount,
			{
				total_amount: paymentSession.monthly_amount +
					paymentSession.annual_amount,
				coupon_id: paymentSession.coupon_id,
				discounted_monthly_amount:
					paymentSession.discounted_monthly_amount || 0,
				discounted_annual_amount:
					paymentSession.discounted_annual_amount || 0,
				discount_percentage: paymentSession.discount_percentage || 0,
			},
		));
	}

	// Otherwise, refresh the preview amounts using Stripe's Invoice Preview API
	try {
		const result = await refreshPreviewAmounts(
			paymentSession.customer_id,
			paymentSession.coupon_id,
			kysely,
			paymentSession.id, // Pass as number, not string
		);
		// Return the result with prorated amounts from the refreshPreviewAmounts function
		// Create subscription objects for pricing info generation
		const monthlySubscription = {
			plan: { amount: result.monthlyAmount },
		} as unknown as SubscriptionWithPlan;

		const annualSubscription = {
			plan: { amount: result.annualAmount },
		} as unknown as SubscriptionWithPlan;
		// Generate pricing info using the session data we've constructed
		const pricingInfo = generatePricingInfo(
			monthlySubscription,
			annualSubscription,
			result.proratedMonthlyAmount,
			result.proratedAnnualAmount,
			{
				total_amount: result.proratedMonthlyAmount +
					result.proratedAnnualAmount,
				coupon_id: paymentSession.coupon_id,
				discounted_monthly_amount: 0,
				discounted_annual_amount: 0,
				discount_percentage: paymentSession.discount_percentage || 0,
			},
		);

		return Response.json(pricingInfo);
	} catch (err) {
		Sentry.captureException(err, {
			extra: {
				message: "Failed to generate pricing preview",
				invitationId: params.invitationId,
				paymentSessionId: paymentSession.id,
			},
		});
		throw error(500, "Failed to generate pricing preview");
	}
};

/**
 * POST handler for applying coupon codes to a payment session
 * Validates the coupon code and updates the payment session with discounted amounts
 */

// Define the schema for coupon code validation
const CouponSchema = v.object({
	code: v.pipe(
		v.string(),
		v.minLength(1, "Coupon code is required"),
		v.maxLength(100, "Coupon code is too long"),
		v.regex(/^[A-Za-z0-9_-]+$/, "Coupon code contains invalid characters"),
	),
});

export const POST: RequestHandler = async (
	{ request, params, platform = {} },
) => {
	// Parse and validate the request body
	const body = v.safeParse(CouponSchema, await request.json());
	if (!body.success) {
		return Response.json({
			message: "Invalid coupon code",
		}, { status: 400 });
	}
	const { code } = body.output;

	const kysely = getKyselyClient(platform.env.HYPERDRIVE);

	// Get invitation and user data
	const invitation = await kysely
		.selectFrom("invitations")
		.select(["user_id", "id"])
		.where((eb) => eb("id", "=", params?.invitationId || ""))
		.where((eb) => eb("status", "=", "pending"))
		.executeTakeFirst();

	if (!invitation || !invitation.user_id) {
		throw error(404, "Invalid invitation");
	}

	// Get payment session data with all necessary fields
	const paymentSession = await getPaymentSession(invitation.user_id, kysely);

	if (!paymentSession || !paymentSession.customer_id) {
		throw error(404, "Invalid payment session");
	}

	// Check if this is the special migration code
	const isMigrationCode = code === DASHBOARD_MIGRATION_CODE;

	// If it's not the migration code, verify it's a valid promotion code
	if (!isMigrationCode) {
		// Verify the coupon code exists and is active
		const promotionCodes = await stripeClient.promotionCodes.list({
			active: true,
			code,
		});

		if (!promotionCodes || promotionCodes.data.length === 0) {
			return Response.json({ message: "Coupon code not valid." }, {
				status: 400,
			});
		}

		// Check if this is a 'forever' duration coupon with 'amount_off' which is no longer supported
		const couponDetails = await stripeClient.coupons.retrieve(
			promotionCodes.data[0].coupon.id,
		);

		if (couponDetails.duration === "forever" && couponDetails.amount_off) {
			return Response.json(
				{
					message:
						"This coupon type is no longer supported. Please contact support.",
				},
				{ status: 400 },
			);
		}
	}

	try {
		// Refresh the preview amounts with the new coupon
		const result = await refreshPreviewAmounts(
			paymentSession.customer_id,
			code, // Use the new coupon code
			kysely,
			paymentSession.id,
		);
		// Return the result with prorated amounts from the refreshPreviewAmounts function
		// Create subscription objects for pricing info generation
		const monthlySubscription = {
			plan: { amount: result.monthlyAmount },
		} as unknown as SubscriptionWithPlan;

		const annualSubscription = {
			plan: { amount: result.annualAmount },
		} as unknown as SubscriptionWithPlan;

		// Generate pricing info using the session data we've constructed
		const pricingInfo = generatePricingInfo(
			monthlySubscription,
			annualSubscription,
			result.proratedMonthlyAmount,
			result.proratedAnnualAmount,
			{
				total_amount: result.proratedMonthlyAmount +
					result.proratedAnnualAmount,
				coupon_id: code || null,
				discounted_monthly_amount: result.proratedMonthlyAmount,
				discounted_annual_amount: result.proratedAnnualAmount,
				discount_percentage: paymentSession.discount_percentage || 0,
			},
		);

		// Update the payment session with the coupon ID
		await kysely
			.updateTable("payment_sessions")
			.set({ coupon_id: code })
			.where("id", "=", paymentSession.id)
			.execute();

		return Response.json(pricingInfo);
	} catch (err) {
		Sentry.captureException(err, {
			extra: {
				message: "Failed to apply coupon",
				invitationId: params.invitationId,
				paymentSessionId: paymentSession.id,
				couponCode: code,
			},
		});
		return Response.json({ message: "Failed to apply coupon" }, {
			status: 500,
		});
	}
};
