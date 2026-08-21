import { onboardingStartDiscord } from "@dhc/api-client";
import { redirect, type RequestHandler } from "@sveltejs/kit";
import {
	hasInvitationAcceptanceProof,
	invitationAcceptanceApiOptions,
} from "$lib/server/invitation-acceptance-proof";
import { forwardTrustedResponseCookie } from "$lib/server/trusted-cookie-forwarding";

const OAUTH_SESSION_COOKIE = "_dhc_key";
const ACCEPTANCE_RECOVERY_COOKIE = "discord-acceptance-invitation";
const ACCEPTANCE_CALLBACK_PATH = "/auth/discord/acceptance/callback";

export const GET: RequestHandler = async ({ cookies, params, url }) => {
	const invitationId = params.invitationId;
	if (!invitationId) throw redirect(303, "/");

	if (!hasInvitationAcceptanceProof(cookies))
		throw redirect(303, `/members/signup/${invitationId}`);

	const result = await onboardingStartDiscord({
		...invitationAcceptanceApiOptions(cookies),
		redirect: "manual",
	});
	const response = result.response;
	if (!response) throw redirect(303, `/members/signup/${invitationId}`);
	const location = response.headers.get("location");
	if (response.status !== 302 || !location)
		throw redirect(303, `/members/signup/${invitationId}`);

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
