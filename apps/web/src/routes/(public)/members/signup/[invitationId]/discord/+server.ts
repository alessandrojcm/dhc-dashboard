import { onboardingStartDiscord } from "@dhc/api-client";
import { redirect, type RequestHandler } from "@sveltejs/kit";
import { apiBaseUrl } from "$lib/server/api-client";

export const GET: RequestHandler = async ({ cookies, params }) => {
	const proof = cookies.get(`onboarding-acceptance-${params.invitationId}`);
	if (!proof) throw redirect(303, `/members/signup/${params.invitationId}`);

	const result = await onboardingStartDiscord({
		baseUrl: apiBaseUrl(),
		auth: proof,
		redirect: "manual",
	});
	const response = result.response;
	if (!response) throw redirect(303, `/members/signup/${params.invitationId}`);
	const location = response.headers.get("location");
	if (response.status !== 302 || !location)
		throw redirect(303, `/members/signup/${params.invitationId}`);

	const setCookies = response.headers.getSetCookie?.() ?? [];
	for (const value of setCookies)
		cookies.set(
			value.split("=", 1)[0],
			value.slice(value.indexOf("=") + 1).split(";", 1)[0],
			{ path: "/", httpOnly: true, sameSite: "lax" },
		);
	throw redirect(302, location);
};
