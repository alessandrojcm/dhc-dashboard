import type { AcceptanceApiResult } from "$lib/invitation-acceptance/vocabulary";

/**
 * Ports for the Invitation Acceptance workflow (GH-509, "remote but owned").
 *
 * The workflow speaks only these two interfaces. Production adapters wrap the
 * generated `@dhc/api-client` operations and SvelteKit `cookies`; tests use
 * the in-memory adapters in `./testing`.
 */

/** The opaque handle: the signed `_dhc_onboarding_acceptance` cookie value. */
export type AcceptanceProof = string;

export type InvitationCredentials = {
	invitationId: string;
	email: string;
	/** ISO date, `YYYY-MM-DD`. */
	dateOfBirth: string;
};

export type PaymentSubmission = {
	nextOfKinName: string;
	nextOfKinPhone: string;
	stripeConfirmationToken?: string;
	couponCode?: string;
	mandateContext: {
		ipAddress: string;
		userAgent?: string;
	};
};

export type VerificationResult = {
	result: AcceptanceApiResult;
	/** Proof issued by Phoenix through `Set-Cookie`, if any. */
	issuedProof: AcceptanceProof | undefined;
};

export interface InvitationAcceptanceApi {
	verify(
		proof: AcceptanceProof | undefined,
		credentials: InvitationCredentials,
	): Promise<VerificationResult>;
	show(proof: AcceptanceProof): Promise<AcceptanceApiResult>;
	continueAcceptance(proof: AcceptanceProof): Promise<AcceptanceApiResult>;
	submitPayment(
		proof: AcceptanceProof,
		payment: PaymentSubmission,
	): Promise<AcceptanceApiResult>;
	retry(proof: AcceptanceProof): Promise<AcceptanceApiResult>;
	cancelDiscord(proof: AcceptanceProof): Promise<AcceptanceApiResult>;
}

/**
 * Request-local cookie store for the two cookies this workflow owns: the
 * acceptance proof and the post-acceptance sign-in prefill. Names, paths, and
 * lifetimes are adapter policy; the workflow only requests effects.
 */
export interface AcceptanceCookieStore {
	readProof(): AcceptanceProof | undefined;
	storeProof(proof: AcceptanceProof): void;
	clearProof(): void;
	storeSignInPrefill(invitationEmail: string): void;
}

export type InvitationAcceptanceDeps = {
	api: InvitationAcceptanceApi;
	cookies: AcceptanceCookieStore;
};
