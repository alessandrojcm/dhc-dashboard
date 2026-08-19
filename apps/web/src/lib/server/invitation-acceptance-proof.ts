import { dev } from "$app/environment";
import { apiBaseUrl } from "$lib/server/api-client";
import { trustedResponseCookie } from "$lib/server/trusted-cookie-forwarding";
import type { Cookies } from "@sveltejs/kit";

const acceptanceProofCookie = "_dhc_onboarding_acceptance";

type ProofReader = {
	get(name: string): string | undefined;
};

type ProofWriter = Pick<Cookies, "set">;
type ProofCookies = Pick<Cookies, "get" | "delete">;

export function hasInvitationAcceptanceProof(cookies: ProofReader): boolean {
	return Boolean(cookies.get(acceptanceProofCookie));
}

export function invitationAcceptanceApiOptions(cookies: ProofReader) {
	const proof = cookies.get(acceptanceProofCookie);

	return {
		baseUrl: apiBaseUrl(),
		credentials: "include" as const,
		headers: proof
			? { cookie: `${acceptanceProofCookie}=${proof}` }
			: undefined,
	};
}

export function relayInvitationAcceptanceProof(
	cookies: ProofWriter,
	headers: Headers,
): boolean {
	const proof = trustedResponseCookie(headers, acceptanceProofCookie);
	if (!proof) return false;

	cookies.set(acceptanceProofCookie, proof.value, {
		encode: (value) => value,
		httpOnly: true,
		maxAge: 15 * 60,
		path: "/",
		sameSite: "lax",
		secure: !dev,
	});
	return true;
}

export function clearInvitationAcceptanceProof(cookies: ProofCookies): void {
	cookies.delete(acceptanceProofCookie, { path: "/" });
}
