import { getRequestEvent, query } from "$app/server";
import { error, isHttpError } from "@sveltejs/kit";
import * as Sentry from "@sentry/sveltekit";
import * as v from "valibot";
import { onboardingPreviewPricing } from "@dhc/api-client";
import { invitationAcceptanceApiOptions } from "$lib/server/invitation-acceptance-proof";
import type { PlanPricing } from "$lib/types";
import { apiErrorDetail } from "$lib/api-error";

const pricingSchema = v.object({
	code: v.optional(v.string()),
});

const dineroAmountSchema = v.object({
	amount: v.number(),
	currency: v.literal("EUR"),
	precision: v.number(),
});

const planPricingSchema = v.object({
	complimentary: v.optional(v.boolean()),
	proratedPrice: dineroAmountSchema,
	proratedMonthlyPrice: dineroAmountSchema,
	proratedAnnualPrice: dineroAmountSchema,
	monthlyFee: dineroAmountSchema,
	annualFee: dineroAmountSchema,
	discountedMonthlyFee: v.optional(dineroAmountSchema),
	discountedAnnualFee: v.optional(dineroAmountSchema),
	coupon: v.optional(v.string()),
	discountPercentage: v.optional(v.number()),
});

/**
 * Pricing follows the acceptance session, not the invitation id: Phoenix
 * resolves the invitation from the signed acceptance cookie relayed by
 * `invitationAcceptanceApiOptions`.
 */
export const getPricingDetail = query(pricingSchema, async ({ code }) => {
	const event = getRequestEvent();
	try {
		const response = await onboardingPreviewPricing({
			...invitationAcceptanceApiOptions(event.cookies),
			query: code ? { code } : undefined,
		});

		if (response.error || !response.data?.data) {
			const detail = apiErrorDetail(response.error);
			const status = response.response?.status ?? 500;
			throw error(status, detail ?? "Failed to get pricing details");
		}

		return v.parse(planPricingSchema, response.data.data) satisfies PlanPricing;
	} catch (err) {
		Sentry.captureException(err);
		if (isHttpError(err)) throw err;
		throw error(500, "Failed to get pricing details");
	}
});
