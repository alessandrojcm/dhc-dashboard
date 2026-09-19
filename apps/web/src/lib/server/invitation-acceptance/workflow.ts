import type { AcceptanceApiResult } from "$lib/invitation-acceptance/vocabulary";
import type { PlanPricing } from "$lib/types";
import {
	decideInvitationRoute,
	type InvitationRouteOutcome,
	type RouteEffect,
} from "./decision";
import type {
	AcceptanceProof,
	InvitationAcceptanceApi,
	InvitationAcceptanceDeps,
	InvitationCredentials,
	PaymentSubmission,
} from "./ports";

/**
 * Workflow operations of the Invitation Acceptance boundary (GH-509).
 *
 * Each operation reads the request-local proof, asks Phoenix through the API
 * port, and converges on `decideInvitationRoute` so the initial page, the
 * resume page, and every remote command react to a Phoenix status in one
 * place. Operations return outcomes with *requested* effects and never write
 * a cookie themselves; `applyInvitationRouteOutcome` performs them.
 */

export type PaymentOutcome =
	| Extract<InvitationRouteOutcome, { type: "SHOW" | "REDIRECT_TO_SUCCESS" }>
	| {
			type: "PAYMENT_FAILED";
			message: string;
			/** `false` once the proof is gone and the invitee must verify again. */
			recoverable: boolean;
			effects: RouteEffect[];
	  };

export type VerificationOutcome =
	| { type: "VERIFIED"; effects: RouteEffect[] }
	| {
			type: "REJECTED";
			reason:
				| "restart"
				| "no_proof_issued"
				| "unexpected_state"
				| "unavailable";
			effects: RouteEffect[];
	  };

export type RestartOutcome = Extract<
	InvitationRouteOutcome,
	{ type: "RESTART_VERIFICATION" }
>;

export type PricingOutcome =
	| { type: "PRICING"; pricing: PlanPricing; effects: RouteEffect[] }
	| InvitationRouteOutcome;

/** Phoenix answers a terminally declined payment with 402, whatever the safe view says. */
const PAYMENT_DECLINED_HTTP_STATUS = 402;

export const paymentMessages = {
	expired: "Invitation verification has expired. Please verify again.",
	rejected: "Payment could not be completed",
	failed: "Invitation acceptance failed",
	timeout:
		"Invitation acceptance is taking longer than expected. Please wait a moment and try again.",
	unavailable:
		"Invitation acceptance is temporarily unavailable. Please try again in a moment.",
} as const;

async function decideAfter(
	deps: InvitationAcceptanceDeps,
	operation: (
		api: InvitationAcceptanceApi,
		proof: AcceptanceProof,
	) => Promise<AcceptanceApiResult>,
): Promise<InvitationRouteOutcome> {
	const proof = deps.cookies.readProof();
	if (!proof) return decideInvitationRoute({ hasAcceptanceProof: false });

	const result = await operation(deps.api, proof);
	return decideInvitationRoute({ hasAcceptanceProof: true, result });
}

/** Initial `/members/signup/[invitationId]` load. */
export function readInvitationPage(deps: InvitationAcceptanceDeps) {
	return decideAfter(deps, (api, proof) => api.show(proof));
}

/**
 * `/members/signup/[invitationId]/resume`: read, and when Phoenix says an
 * explicit retry is allowed, retry once and decide on the retry's answer.
 */
export async function resumeInvitationAcceptance(
	deps: InvitationAcceptanceDeps,
): Promise<InvitationRouteOutcome> {
	const current = await readInvitationPage(deps);
	if (current.type !== "SHOW" || current.view.retryAllowed !== true) {
		return current;
	}

	return decideAfter(deps, (api, proof) => api.retry(proof));
}

/** Consume verified Discord proof and authorize the payment form. */
export function continueToPayment(deps: InvitationAcceptanceDeps) {
	return decideAfter(deps, (api, proof) => api.continueAcceptance(proof));
}

/**
 * Submit payment details. Phoenix owns the Stripe workflow and idempotency;
 * this only interprets its answer. Any non-2xx answer that still leaves the
 * session alive is a recoverable failure the payment UI can retry.
 */
export async function submitInvitationPayment(
	deps: InvitationAcceptanceDeps,
	payment: PaymentSubmission,
): Promise<PaymentOutcome> {
	const proof = deps.cookies.readProof();
	if (!proof) {
		return {
			type: "PAYMENT_FAILED",
			message: paymentMessages.expired,
			recoverable: false,
			effects: [{ type: "clearAcceptanceProof" }],
		};
	}

	const result = await deps.api.submitPayment(proof, payment);
	const outcome = decideInvitationRoute({ hasAcceptanceProof: true, result });

	switch (outcome.type) {
		case "REDIRECT_TO_SUCCESS":
			return outcome;
		case "RESTART_VERIFICATION":
			// Phoenix concludes a terminally declined payment synchronously: the
			// Continuation is already `failed`, so the safe view is
			// `restartVerification`, but it answers 402 (not 409) precisely so
			// the invitee is told the payment was declined rather than that
			// their verification expired.
			return {
				type: "PAYMENT_FAILED",
				message:
					result.kind === "view" &&
					result.httpStatus === PAYMENT_DECLINED_HTTP_STATUS
						? paymentMessages.rejected
						: paymentMessages.expired,
				recoverable: false,
				effects: outcome.effects,
			};
		case "SHOW":
			if (result.kind === "view" && result.httpStatus < 400) return outcome;
			return {
				type: "PAYMENT_FAILED",
				message: paymentFailureMessage(result),
				recoverable: true,
				effects: [],
			};
		case "UNAVAILABLE":
		case "REJECTED":
			return {
				type: "PAYMENT_FAILED",
				message: paymentFailureMessage(result),
				recoverable: true,
				effects: [],
			};
	}
}

function paymentFailureMessage(result: AcceptanceApiResult): string {
	switch (result.kind) {
		case "unavailable":
			return result.reason === "timeout"
				? paymentMessages.timeout
				: paymentMessages.unavailable;
		case "rejected":
			if (result.detail) return result.detail;
			if (result.httpStatus === PAYMENT_DECLINED_HTTP_STATUS)
				return paymentMessages.rejected;
			if (result.httpStatus >= 500) return paymentMessages.unavailable;
			return paymentMessages.failed;
		case "view":
			return result.httpStatus === PAYMENT_DECLINED_HTTP_STATUS
				? paymentMessages.rejected
				: paymentMessages.failed;
		case "unexpected_response":
			return paymentMessages.failed;
	}
}

/**
 * Handle-bound pricing preview. A `restartVerification` answer is the same
 * outcome the page and every other command produce — including clearing the
 * stale proof — so a later retry is not stuck on a dead handle.
 */
export async function previewPricing(
	deps: InvitationAcceptanceDeps,
	code?: string,
): Promise<PricingOutcome> {
	const proof = deps.cookies.readProof();
	if (!proof) return decideInvitationRoute({ hasAcceptanceProof: false });

	const result = await deps.api.previewPricing(proof, code);
	if (result.kind === "pricing") {
		return { type: "PRICING", pricing: result.pricing, effects: [] };
	}

	return decideInvitationRoute({ hasAcceptanceProof: true, result });
}

/**
 * Prove Invitation credentials. A stale proof is forwarded so Phoenix can
 * resume the live flow; the proof Phoenix issues in return becomes the new
 * handle. Nothing is stored unless Phoenix moved to `awaitingDiscord` *and*
 * issued a proof.
 */
export async function verifyInvitationCredentials(
	deps: InvitationAcceptanceDeps,
	credentials: InvitationCredentials,
): Promise<VerificationOutcome> {
	const { result, issuedProof } = await deps.api.verify(
		deps.cookies.readProof(),
		credentials,
	);
	const outcome = decideInvitationRoute({ hasAcceptanceProof: true, result });

	if (outcome.type === "RESTART_VERIFICATION") {
		return { type: "REJECTED", reason: "restart", effects: outcome.effects };
	}
	if (outcome.type === "UNAVAILABLE") {
		return { type: "REJECTED", reason: "unavailable", effects: [] };
	}
	if (outcome.type !== "SHOW" || outcome.view.state !== "awaitingDiscord") {
		return { type: "REJECTED", reason: "unexpected_state", effects: [] };
	}
	if (!issuedProof) {
		return { type: "REJECTED", reason: "no_proof_issued", effects: [] };
	}

	return {
		type: "VERIFIED",
		effects: [{ type: "storeProof", proof: issuedProof }],
	};
}

/**
 * Release the Discord claim and forget the proof. The proof is cleared even
 * when Phoenix cannot be reached: the browser must never keep a handle it has
 * asked to abandon.
 */
export async function restartDiscordVerification(
	deps: InvitationAcceptanceDeps,
): Promise<RestartOutcome> {
	const proof = deps.cookies.readProof();
	if (proof) {
		await deps.api.cancelDiscord(proof);
	}

	return {
		type: "RESTART_VERIFICATION",
		effects: [{ type: "clearAcceptanceProof" }],
	};
}
