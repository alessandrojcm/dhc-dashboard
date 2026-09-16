import { error, redirect } from "@sveltejs/kit";
import { invitationPaths } from "$lib/invitation-acceptance/paths";
import type { AcceptanceView } from "$lib/invitation-acceptance/vocabulary";
import type { InvitationRouteOutcome, RouteEffect } from "./decision";
import type { AcceptanceCookieStore } from "./ports";

/**
 * The effect side of the boundary. Workflow operations only *request* cookie
 * effects; route adapters call these to perform them and to turn an outcome
 * into what SvelteKit understands: data to render, or a thrown redirect/error.
 */

export function applyRouteEffects(
	effects: readonly RouteEffect[],
	cookies: AcceptanceCookieStore,
): void {
	for (const effect of effects) {
		switch (effect.type) {
			case "clearAcceptanceProof":
				cookies.clearProof();
				break;
			case "storeProof":
				cookies.storeProof(effect.proof);
				break;
			case "establishSignInHandoff":
				if (effect.invitationEmail) {
					cookies.storeSignInPrefill(effect.invitationEmail);
				}
				break;
		}
	}
}

export type ApplyRouteOutcomeOptions = {
	cookies: AcceptanceCookieStore;
	invitationId: string;
	/**
	 * `render`: the caller is the invitation page and receives the view to
	 * render. `redirect`: the caller is a command or the resume page; the
	 * browser is sent back to the invitation page, which renders the state.
	 */
	mode: "render" | "redirect";
};

export const restartView: AcceptanceView = { state: "restartVerification" };

const unavailableMessage =
	"Invitation acceptance is temporarily unavailable. Please try again in a moment.";

/**
 * Perform an outcome's effects, then either return the view to render or
 * throw the SvelteKit redirect/error the outcome calls for. In `redirect`
 * mode every outcome throws, which the `never` overload lets callers rely on.
 */
export function applyInvitationRouteOutcome(
	outcome: InvitationRouteOutcome,
	options: ApplyRouteOutcomeOptions & { mode: "redirect" },
): never;
export function applyInvitationRouteOutcome(
	outcome: InvitationRouteOutcome,
	options: ApplyRouteOutcomeOptions & { mode: "render" },
): AcceptanceView;
export function applyInvitationRouteOutcome(
	outcome: InvitationRouteOutcome,
	{ cookies, invitationId, mode }: ApplyRouteOutcomeOptions,
): AcceptanceView {
	applyRouteEffects(outcome.effects, cookies);

	switch (outcome.type) {
		case "REDIRECT_TO_SUCCESS":
			return redirect(303, invitationPaths.success(invitationId));
		case "SHOW":
			if (mode === "redirect")
				redirect(303, invitationPaths.page(invitationId));
			return outcome.view;
		case "RESTART_VERIFICATION":
			if (mode === "redirect")
				redirect(303, invitationPaths.page(invitationId));
			return restartView;
		case "UNAVAILABLE":
			return error(503, outcome.detail ?? unavailableMessage);
		case "REJECTED":
			return error(
				outcome.httpStatus,
				outcome.detail ?? "Invitation acceptance failed",
			);
	}
}
