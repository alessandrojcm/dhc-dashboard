/**
 * Invitation Acceptance workflow boundary (GH-509).
 *
 * Public surface: workflow operations, typed outcomes/effects, the two ports,
 * their production adapters, and `applyInvitationRouteOutcome`. Phoenix status
 * interpretation, valid transitions, and the rules connecting outcomes to
 * cookie effects stay private to this directory.
 *
 * Nothing here creates an actor: server decisions run through XState's pure
 * transition functions, and SvelteKit server modules are shared across
 * requests. Do not add module-scope actors.
 */

import type { Cookies } from "@sveltejs/kit";
import { apiClientAcceptanceApi } from "./api-client-adapter";
import { sveltekitAcceptanceCookies } from "./cookie-store";
import type { InvitationAcceptanceDeps } from "./ports";

export {
	applyInvitationRouteOutcome,
	applyRouteEffects,
	restartView,
	type ApplyRouteOutcomeOptions,
} from "./apply";
export {
	decideInvitationRoute,
	type InvitationDecisionInput,
	type InvitationRouteOutcome,
	type RouteEffect,
} from "./decision";
export type {
	AcceptanceCookieStore,
	AcceptanceProof,
	InvitationAcceptanceApi,
	InvitationAcceptanceDeps,
	InvitationCredentials,
	PaymentSubmission,
	PricingApiResult,
} from "./ports";
export {
	continueToPayment,
	paymentMessages,
	previewPricing,
	readInvitationPage,
	restartDiscordVerification,
	resumeInvitationAcceptance,
	submitInvitationPayment,
	verifyInvitationCredentials,
	type PaymentOutcome,
	type PricingOutcome,
	type RestartOutcome,
	type VerificationOutcome,
} from "./workflow";
export {
	consumeInvitationSignInPrefill,
	sveltekitAcceptanceCookies,
} from "./cookie-store";
export {
	apiClientAcceptanceApi,
	invitationAcceptanceRequestOptions,
} from "./api-client-adapter";

/** Production dependencies for one request. */
export function invitationAcceptanceDeps(
	cookies: Pick<Cookies, "get" | "set" | "delete">,
): InvitationAcceptanceDeps {
	return {
		api: apiClientAcceptanceApi(),
		cookies: sveltekitAcceptanceCookies(cookies),
	};
}
