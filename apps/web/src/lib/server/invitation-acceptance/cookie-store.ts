import { dev } from "$app/environment";
import type { Cookies } from "@sveltejs/kit";
import { trustedResponseCookie } from "$lib/server/trusted-cookie-forwarding";
import type { AcceptanceCookieStore, AcceptanceProof } from "./ports";

/**
 * SvelteKit adapter for the acceptance cookie store. Owns the two cookie names
 * and their browser lifetimes; nothing else in the app spells them.
 */

export const acceptanceProofCookie = "_dhc_onboarding_acceptance";
const signInPrefillCookie = "invitation-sign-in-prefill";

const proofLifetimeSeconds = 15 * 60;
const prefillLifetimeSeconds = 10 * 60;
const prefillPath = "/auth";

type StoreCookies = Pick<Cookies, "get" | "set" | "delete">;
type PrefillCookies = Pick<Cookies, "get" | "delete">;

export function sveltekitAcceptanceCookies(
	cookies: StoreCookies,
): AcceptanceCookieStore {
	return {
		readProof: () => cookies.get(acceptanceProofCookie) || undefined,
		storeProof(proof: AcceptanceProof) {
			cookies.set(acceptanceProofCookie, proof, {
				// The value is Phoenix's signed token; never re-encode it.
				encode: (value) => value,
				httpOnly: true,
				maxAge: proofLifetimeSeconds,
				path: "/",
				sameSite: "lax",
				secure: !dev,
			});
		},
		clearProof() {
			cookies.delete(acceptanceProofCookie, { path: "/" });
		},
		storeSignInPrefill(invitationEmail: string) {
			cookies.set(signInPrefillCookie, invitationEmail, {
				path: prefillPath,
				httpOnly: true,
				secure: !dev,
				sameSite: "lax",
				maxAge: prefillLifetimeSeconds,
			});
		},
	};
}

/** Read the proof Phoenix issued on a trusted upstream response, if any. */
export function issuedProofFrom(headers: Headers): AcceptanceProof | undefined {
	return trustedResponseCookie(headers, acceptanceProofCookie)?.value;
}

/** Consumed by `/auth` to prefill ordinary sign-in once after acceptance. */
export function consumeInvitationSignInPrefill(
	cookies: PrefillCookies,
): string | undefined {
	const prefillEmail = cookies.get(signInPrefillCookie);
	if (prefillEmail) {
		cookies.delete(signInPrefillCookie, { path: prefillPath });
	}

	return prefillEmail;
}
