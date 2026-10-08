import { getRequestEvent, query } from "$app/server";
import { error, isHttpError } from "@sveltejs/kit";
import * as Sentry from "@sentry/sveltekit";
import * as v from "valibot";
import {
	invitationAcceptanceDeps,
	readInvitationPricing,
} from "#lib/server/invitation-acceptance/index.js";

const pricingSchema = v.object({
	code: v.optional(v.string()),
});

/**
 * Pricing follows the acceptance session, not the invitation id. The workflow
 * interprets Phoenix's answer (including `restartVerification`), but queries
 * cannot write cookies. The page load or a command applies cleanup effects.
 */
export const getPricingDetail = query(pricingSchema, async ({ code }) => {
	const event = getRequestEvent();
	try {
		const deps = invitationAcceptanceDeps(event.cookies);
		return await readInvitationPricing(deps, code);
	} catch (err) {
		if (isHttpError(err)) throw err;
		Sentry.captureException(err);
		throw error(500, "Failed to get pricing details");
	}
});
