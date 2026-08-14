import { onboardingCancelDiscord } from "@dhc/api-client";
import { redirect, type RequestHandler } from "@sveltejs/kit";
import { apiBaseUrl } from "$lib/server/api-client";

// Deliberately no continuation in this URL: the protected cookie is the only
// browser-held reference used to release the claim.
export const POST: RequestHandler = async ({ cookies, params }) => {
	const proof = cookies.get(`onboarding-acceptance-${params.invitationId}`);
	if (proof) {
		await onboardingCancelDiscord({
			baseUrl: apiBaseUrl(),
			auth: proof,
		});
	}
	cookies.delete(`onboarding-acceptance-${params.invitationId}`, {
		path: `/members/signup/${params.invitationId}`,
	});
	throw redirect(303, `/members/signup/${params.invitationId}`);
};
