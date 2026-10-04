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
export const GET: RequestHandler = async ({ cookies, fetch, params, url }) => {
	const invitationId = params.invitationId;
	if (!invitationId) throw redirect(303, "/");

	const proof = sveltekitAcceptanceCookies(cookies).readProof();
	if (!proof) throw redirect(303, invitationPaths.page(invitationId));

	// Raw fetch: the OpenAPI contract declares only `302 + Location` (no body),
	// so the generated SDK has no 2xx to parse and throws NonErrorApiFailure
	// on the 302 instead of returning `{ response }`. `redirect: "manual"`
	// stops fetch from following the redirect; the SDK throw happens
	// regardless, so this transport-only route bypasses the SDK entirely.
	const { baseUrl, headers } = invitationAcceptanceRequestOptions(proof);
	const response = await fetch(
		`${baseUrl}/onboarding/invitation-acceptance/discord`,
		{ headers, redirect: "manual" },
	);
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
