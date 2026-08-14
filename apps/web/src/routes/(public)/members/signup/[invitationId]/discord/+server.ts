import { onboardingStartDiscord } from "@dhc/api-client";
import { redirect, type RequestHandler } from "@sveltejs/kit";
import {
	onboardingAcceptanceCookie,
	onboardingApiClientOptions,
} from "$lib/server/onboarding-api";

const ACCEPTANCE_RECOVERY_COOKIE = "discord-acceptance-invitation";
const ACCEPTANCE_CALLBACK_PATH = "/auth/discord/acceptance/callback";

export const GET: RequestHandler = async ({ cookies, params }) => {
	const invitationId = params.invitationId;
	if (!invitationId) throw redirect(303, "/");

	const proof = cookies.get(onboardingAcceptanceCookie);
	if (!proof) throw redirect(303, `/members/signup/${invitationId}`);

	const result = await onboardingStartDiscord({
		...onboardingApiClientOptions(cookies),
		redirect: "manual",
	});
	const response = result.response;
	if (!response) throw redirect(303, `/members/signup/${invitationId}`);
	const location = response.headers.get("location");
	if (response.status !== 302 || !location)
		throw redirect(303, `/members/signup/${invitationId}`);

	const setCookies = response.headers.getSetCookie?.() ?? [];
	for (const value of setCookies)
		cookies.set(
			value.split("=", 1)[0],
			value.slice(value.indexOf("=") + 1).split(";", 1)[0],
			{ path: "/", httpOnly: true, sameSite: "lax" },
		);
	cookies.set(ACCEPTANCE_RECOVERY_COOKIE, invitationId, {
		path: ACCEPTANCE_CALLBACK_PATH,
		httpOnly: true,
		sameSite: "lax",
		maxAge: 15 * 60,
	});
	throw redirect(302, location);
};
