import { error } from "@sveltejs/kit";
import type { PlanPricing } from "#lib/types.js";
import type { InvitationAcceptanceDeps } from "./ports";
import { previewPricing } from "./workflow";

/**
 * Read-only remote-query boundary. SvelteKit forbids cookie writes in queries;
 * the page load or a command applies any cleanup requested by the workflow.
 */
export async function readInvitationPricing(
	deps: InvitationAcceptanceDeps,
	code?: string,
): Promise<PlanPricing> {
	const outcome = await previewPricing(deps, code);
	switch (outcome.type) {
		case "PRICING":
			return outcome.pricing;
		case "UNAVAILABLE":
			return error(
				503,
				outcome.detail ??
					"Invitation acceptance is temporarily unavailable. Please try again in a moment.",
			);
		case "REJECTED": {
			const status =
				outcome.httpStatus >= 400 && outcome.httpStatus <= 599
					? outcome.httpStatus
					: 502;
			return error(status, outcome.detail ?? "Failed to get pricing details");
		}
		default:
			return error(409, "Failed to get pricing details");
	}
}
