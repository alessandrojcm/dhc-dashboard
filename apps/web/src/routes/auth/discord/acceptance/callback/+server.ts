import { redirect, type RequestHandler } from "@sveltejs/kit";
import { apiBaseUrl } from "$lib/server/api-client";

const OAUTH_SESSION_COOKIE = "_dhc_key";
const ACCEPTANCE_RECOVERY_COOKIE = "discord-acceptance-invitation";
const UUID_PATTERN =
	/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const GET: RequestHandler = async ({ cookies, fetch, url }) => {
	const invitationId = cookies.get(ACCEPTANCE_RECOVERY_COOKIE);
	const restartPath =
		invitationId && UUID_PATTERN.test(invitationId)
			? `/members/signup/${invitationId}`
			: "/";
	const oauthSession = cookies.get(OAUTH_SESSION_COOKIE);
	if (!oauthSession) throw redirect(303, restartPath);

	const callbackUrl = new URL(`${apiBaseUrl()}/auth/discord/callback`);
	callbackUrl.search = url.search;

	const response = await fetch(callbackUrl, {
		headers: {
			cookie: `${OAUTH_SESSION_COOKIE}=${encodeURIComponent(oauthSession)}`,
			"x-discord-oauth-purpose": "invitation_acceptance",
		},
		redirect: "manual",
	});
	cookies.delete(OAUTH_SESSION_COOKIE, { path: "/" });

	const location = response.headers.get("location");
	if (response.status !== 302 || !location) throw redirect(303, restartPath);

	const destination = new URL(location);
	if (
		destination.origin !== url.origin ||
		!destination.pathname.startsWith("/members/signup/")
	)
		throw redirect(303, restartPath);

	if (destination.pathname === "/members/signup/restart")
		throw redirect(303, restartPath);

	throw redirect(302, destination.pathname + destination.search);
};
