import { redirect, type RequestHandler } from "@sveltejs/kit";
import { apiBaseUrl } from "$lib/server/api-client";

const OAUTH_SESSION_COOKIE = "_dhc_key";
const RESTART_PATH = "/members/signup/restart";

export const GET: RequestHandler = async ({ cookies, fetch, url }) => {
	const oauthSession = cookies.get(OAUTH_SESSION_COOKIE);
	if (!oauthSession) throw redirect(303, RESTART_PATH);

	const callbackUrl = new URL(`${apiBaseUrl()}/auth/discord/callback`);
	callbackUrl.search = url.search;

	const response = await fetch(callbackUrl, {
		headers: {
			cookie: `${OAUTH_SESSION_COOKIE}=${encodeURIComponent(oauthSession)}`,
		},
		redirect: "manual",
	});

	cookies.delete(OAUTH_SESSION_COOKIE, { path: "/" });

	const location = response.headers.get("location");
	if (response.status !== 302 || !location) throw redirect(303, RESTART_PATH);

	const destination = new URL(location);
	if (
		destination.origin !== url.origin ||
		!destination.pathname.startsWith("/members/signup/")
	)
		throw redirect(303, RESTART_PATH);

	throw redirect(302, destination.pathname + destination.search);
};
