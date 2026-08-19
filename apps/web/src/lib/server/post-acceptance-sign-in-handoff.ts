import { dev } from "$app/environment";
import { redirect } from "@sveltejs/kit";
import type { Cookies } from "@sveltejs/kit";
import { clearInvitationAcceptanceProof } from "$lib/server/invitation-acceptance-proof";

const signInPrefillCookie = "invitation-sign-in-prefill";

type CompletionCookies = Pick<Cookies, "set" | "delete">;
type PrefillCookies = Pick<Cookies, "get" | "delete">;

export function completeInvitationAcceptance(
	cookies: CompletionCookies,
	invitationEmail: string | undefined,
	invitationId: string,
): never {
	if (invitationEmail) {
		cookies.set(signInPrefillCookie, invitationEmail, {
			path: "/auth",
			httpOnly: true,
			secure: !dev,
			sameSite: "lax",
			maxAge: 10 * 60,
		});
	}

	clearInvitationAcceptanceProof(cookies);
	redirect(303, `/members/signup/${invitationId}/success`);
}

export function consumeInvitationSignInPrefill(
	cookies: PrefillCookies,
): string | undefined {
	const prefillEmail = cookies.get(signInPrefillCookie);
	if (prefillEmail) {
		cookies.delete(signInPrefillCookie, { path: "/auth" });
	}

	return prefillEmail;
}
