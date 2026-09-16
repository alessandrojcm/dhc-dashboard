import { onboardingStartDiscord } from "@dhc/api-client";
import { redirect, type RequestHandler } from "@sveltejs/kit";
import { invitationPaths } from "$lib/invitation-acceptance/paths";
import {
	invitationAcceptanceRequestOptions,
	sveltekitAcceptanceCookies,
} from "$lib/server/invitation-acceptance";
import { forwardTrustedResponseCookie } from "$lib/server/trusted-cookie-forwarding";

const OAUTH_SESSION_COOKIE = "_dhc_key";
const ACCEPTANCE_RECOVERY_COOKIE = "discord-acceptance-invitation";
const ACCEPTANCE_CALLBACK_PATH = "/auth/discord/acceptance/callback";

// Transport only: Phoenix decides whether this session may start OAuth and
// answers with the provider redirect. No workflow decision is made here.
export const GET: RequestHandler = async ({ cookies, params, url }) => {
	const invitationId = params.invitationId;
	if (!invitationId) throw redirect(303, "/");

	const proof = sveltekitAcceptanceCookies(cookies).readProof();
	if (!proof) throw redirect(303, invitationPaths.page(invitationId));

	const result = await onboardingStartDiscord({
		...invitationAcceptanceRequestOptions(proof),
		redirect: "manual",
	});
	const response = result.response;
	if (!response) throw redirect(303, invitationPaths.page(invitationId));
	const location = response.headers.get("location");
	if (response.status !== 302 || !location)
		throw redirect(303, invitationPaths.page(invitationId));

	forwardTrustedResponseCookie(cookies, response.headers, OAUTH_SESSION_COOKIE);
	cookies.set(ACCEPTANCE_RECOVERY_COOKIE, invitationId, {
		path: ACCEPTANCE_CALLBACK_PATH,
		httpOnly: true,
		secure: url.protocol === "https:",
		sameSite: "lax",
		maxAge: 15 * 60,
	});
	throw redirect(302, location);
};
