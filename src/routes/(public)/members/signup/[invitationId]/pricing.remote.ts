import { command, getRequestEvent, query } from "$app/server";
import { error } from "@sveltejs/kit";
import * as Sentry from "@sentry/sveltekit";
import * as v from "valibot";
import { invitationsPricing } from "@dhc/api-client";
import { apiBaseUrl } from "$lib/server/api-client";
import type { PlanPricing } from "$lib/types";

const pricingSchema = v.object({
	code: v.optional(v.string()),
	invitationId: v.pipe(v.string(), v.uuid()),
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

			return response.data.data as PlanPricing;
		} catch (err) {
			Sentry.captureException(err);
			if (err && typeof err === "object" && "status" in err) throw err;
			throw error(500, "Failed to get pricing details");
		}
	},
);

export const applyCoupon = command(pricingSchema, (args) => {
	getPricingDetail(args).refresh();
});
