import { getRequestEvent, query } from "$app/server";
import { error, isHttpError } from "@sveltejs/kit";
import * as Sentry from "@sentry/sveltekit";
import * as v from "valibot";
import {
	applyRouteEffects,
	invitationAcceptanceDeps,
	previewPricing,
	type InvitationRouteOutcome,
} from "$lib/server/invitation-acceptance";
import type { PlanPricing } from "$lib/types";

const pricingSchema = v.object({
	code: v.optional(v.string()),
});

function pricingHttpError(outcome: InvitationRouteOutcome): never {
	switch (outcome.type) {
		case "UNAVAILABLE":
			throw error(
				503,
				outcome.detail ??
					"Invitation acceptance is temporarily unavailable. Please try again in a moment.",
			);
		case "REJECTED": {
			const status =
				outcome.httpStatus >= 400 && outcome.httpStatus <= 599
					? outcome.httpStatus
					: 502;
			throw error(status, outcome.detail ?? "Failed to get pricing details");
		}
		default:
			throw error(409, "Failed to get pricing details");
	}
}

/**
 * Pricing follows the acceptance session, not the invitation id. The workflow
 * interprets Phoenix's answer (including `restartVerification`) so a stale
 * proof is cleared before this query answers the form with data.
 */
export const getPricingDetail = query(pricingSchema, async ({ code }) => {
	const event = getRequestEvent();
	try {
		const deps = invitationAcceptanceDeps(event.cookies);
		const outcome = await previewPricing(deps, code);
		applyRouteEffects(outcome.effects, deps.cookies);
		if (outcome.type === "PRICING")
			return outcome.pricing satisfies PlanPricing;
		pricingHttpError(outcome);
	} catch (err) {
		Sentry.captureException(err);
		if (isHttpError(err)) throw err;
		throw error(500, "Failed to get pricing details");
	}
});
