import { error, json, type RequestHandler } from "@sveltejs/kit";
import { getKyselyClient } from "$lib/server/kysely";

import { refreshPreviewAmounts } from "$lib/server/stripePriceCache";
import { generatePricingInfo } from "$lib/server/pricingUtils";
import type { SubscriptionWithPlan } from "$lib/types";
import * as Sentry from "@sentry/sveltekit";
import { stripeClient } from "$lib/server/stripe";
import { env } from "$env/dynamic/public";
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

async function getManualPricingDetails(
	userId: string,
	kysely: ReturnType<typeof getKyselyClient>,
	paymentSessionId: number,
) {
	// Fetch base Stripe prices
	const prices = await stripeClient.prices.list({
		lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME, ANNUAL_FEE_LOOKUP],
		active: true,
		limit: 2,
	});

	let baseMonthlyPrice = 0;
	let baseAnnualPrice = 0;

	prices.data.forEach((price) => {
		if (
			price.lookup_key === MEMBERSHIP_FEE_LOOKUP_NAME && price.unit_amount
		) {
			baseMonthlyPrice = price.unit_amount;
		}
		if (price.lookup_key === ANNUAL_FEE_LOOKUP && price.unit_amount) {
			baseAnnualPrice = price.unit_amount;
		}
	});

	if (baseMonthlyPrice === 0 || baseAnnualPrice === 0) {
		Sentry.captureMessage("Base prices not found for membership products", {
			extra: { userId, paymentSessionId },
		});
		throw error(500, "Could not retrieve base product prices.");
	}

	// Proration Calculation
	const today = dayjs();
	let finalProratedMonthlyCharge = 0;
	let finalProratedAnnualCharge = 0;

	// Monthly Proration
	const daysInCurrentMonth = today.daysInMonth();
	const daysToProrateForMonthly =
		today.endOf("month").diff(today.startOf("day"), "day") + 1;
	if (daysInCurrentMonth > 0) {
		finalProratedMonthlyCharge = Math.round(
			(baseMonthlyPrice / daysInCurrentMonth) * daysToProrateForMonthly,
		);
	}

	// Annual Proration
	let annualProrationEndDate = dayjs().month(0).date(7).startOf("day"); // January 7th of the current year
	if (today.isSameOrAfter(annualProrationEndDate)) {
		annualProrationEndDate = annualProrationEndDate.add(1, "year"); // January 7th of the next year
	}
	const daysToProrateForAnnual = annualProrationEndDate.diff(
		today.startOf("day"),
		"day",
	);
	const fullAnnualPeriodStartDate = annualProrationEndDate.subtract(
		1,
		"year",
	);
	const daysInFullAnnualPeriod = annualProrationEndDate.diff(
		fullAnnualPeriodStartDate,
		"day",
	);

	if (daysInFullAnnualPeriod > 0 && daysToProrateForAnnual > 0) {
		finalProratedAnnualCharge = Math.round(
			(baseAnnualPrice / daysInFullAnnualPeriod) * daysToProrateForAnnual,
		);
	}

	const totalAmount = finalProratedMonthlyCharge + finalProratedAnnualCharge;

	// Update payment session in DB
	await kysely
		.updateTable("payment_sessions")
		.set({
			monthly_amount: baseMonthlyPrice, // Corrected column name
			annual_amount: baseAnnualPrice, // Corrected column name
			discounted_monthly_amount: 0,
			discounted_annual_amount: 0,
			prorated_monthly_amount: finalProratedMonthlyCharge,
			prorated_annual_amount: finalProratedAnnualCharge,
			discount_percentage: 0,
			total_amount: totalAmount,
			coupon_id: null,
		})
		.where("id", "=", paymentSessionId)
		.execute();

	return {
		baseMonthlyPrice,
		baseAnnualPrice,
		finalProratedMonthlyCharge,
		finalProratedAnnualCharge,
		totalAmount,
	};
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

/**
 * Consolidated endpoint for plan pricing and invoice preview
 * Handles both basic pricing information and detailed invoice preview with proration and discounts
 */
export const GET: RequestHandler = async ({ params, platform }) => {
	const invitationId = params.invitationId;
	if (!invitationId) {
		throw error(400, "Invitation ID is required");
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

	if (!invitation || !invitation.user_id) {
		Sentry.captureMessage(
			`Invitation not found or invalid for ID: ${invitationId}`,
			"warning",
		);
		throw error(404, "Invitation not found, invalid, or expired.");
	}
	const userIdFromInvitation = invitation.user_id;

	// 2. Fetch user_profile to get Stripe customer_id
	const userProfile = await kysely
		.selectFrom("user_profiles")
		.select(["customer_id"])
		.where("supabase_user_id", "=", userIdFromInvitation)
		.executeTakeFirst();

	if (!userProfile || !userProfile.customer_id) {
		Sentry.captureMessage(
			`User profile or Stripe customer_id not found for user_id: ${userIdFromInvitation} from invitation ${invitationId}`,
			"error",
		);
		throw error(
			500,
			"User account configuration error. Missing Stripe customer ID.",
		);
	}
	const stripeCustomerId = userProfile.customer_id;

	// 3. Fetch payment session using user_id
	const paymentSession = await getPaymentSession(
		userIdFromInvitation,
		kysely,
	);

	if (!paymentSession) {
		Sentry.captureMessage(
			`Active payment session not found for user_id: ${userIdFromInvitation} (from invitation ${invitationId}). Attempting to show pricing.`,
			"warning",
		);
		throw error(
			404,
			"Payment session not found. Please ensure the signup process was initiated correctly.",
		);
	}

	// Call the new manual pricing function
	const updatedPaymentSession = await getManualPricingDetails(
		stripeCustomerId,
		kysely,
		paymentSession.id,
	);

	if (!updatedPaymentSession) {
		Sentry.captureMessage(
			`Updated payment session not found after getManualPricingDetails for id: ${paymentSession.id}`,
			"error",
		);
		throw error(500, "Failed to retrieve pricing details after update.");
	}

	// Generate response using the updated session and stubs
	const monthlySubscriptionStub = {
		plan: { amount: updatedPaymentSession.baseMonthlyPrice },
	} as SubscriptionWithPlan;
	const annualSubscriptionStub = {
		plan: { amount: updatedPaymentSession.baseAnnualPrice },
	} as SubscriptionWithPlan;
	return json(
		generatePricingInfo(
			monthlySubscriptionStub,
			annualSubscriptionStub,
			updatedPaymentSession.finalProratedMonthlyCharge,
			updatedPaymentSession.finalProratedAnnualCharge,
			{
				total_amount: updatedPaymentSession.finalProratedAnnualCharge + updatedPaymentSession.finalProratedMonthlyCharge,
				discounted_monthly_amount: 0,
				discounted_annual_amount: 0,
				discount_percentage: 0,
				coupon_id: null,
			}
		),
	);
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

	// If it's not the migration code, verify it's a valid promotion code
	if (
		!isMigrationCode && couponDetails.duration === "forever" &&
		couponDetails.amount_off
	) {
		return Response.json(
			{
				message:
					"This coupon type is no longer supported. Please contact support.",
			},
			{ status: 400 },
		);
	}

	try {
		// Refresh the preview amounts with the new coupon
		const result = await refreshPreviewAmounts(
			paymentSession.customer_id,
			promotionCodes.data[0].id,
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
