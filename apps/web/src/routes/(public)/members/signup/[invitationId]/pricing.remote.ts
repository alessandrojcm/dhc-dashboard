import { getRequestEvent, query } from "$app/server";
import { error, isHttpError } from "@sveltejs/kit";
import * as Sentry from "@sentry/sveltekit";
import * as v from "valibot";
import { invitationsPricing } from "@dhc/api-client";
import { apiBaseUrl } from "$lib/server/api-client";
import type { PlanPricing } from "$lib/types";

const pricingSchema = v.object({
	code: v.optional(v.string()),
	invitationId: v.pipe(v.string(), v.uuid()),
});

const dineroAmountSchema = v.object({
	amount: v.number(),
	currency: v.literal("EUR"),
	precision: v.number(),
});

const planPricingSchema = v.object({
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

export const getPricingDetail = query(
	pricingSchema,
	async ({ invitationId, code }) => {
		getRequestEvent();
		try {
			const response = await invitationsPricing({
				baseUrl: apiBaseUrl(),
				path: { id: invitationId },
				query: code ? { code } : undefined,
			});

			if (response.error || !response.data?.data) {
				const detail = response.error?.errors?.detail;
				const status = response.response?.status ?? 500;
				throw error(status, detail ?? "Failed to get pricing details");
			}

			return v.parse(
				planPricingSchema,
				response.data.data,
			) satisfies PlanPricing;
		} catch (err) {
			Sentry.captureException(err);
			if (isHttpError(err)) throw err;
			throw error(500, "Failed to get pricing details");
		}
	},
);
