import { onboardingCancelDiscord } from "@dhc/api-client";
import { redirect, type RequestHandler } from "@sveltejs/kit";
import { onboardingApiClientOptions } from "$lib/server/onboarding-api";

// Deliberately no continuation in this URL: the protected cookie is the only
// browser-held reference used to release the claim.
export const POST: RequestHandler = async ({ cookies, params }) => {
	const proof = cookies.get("_dhc_onboarding_acceptance");
	if (proof) {
		await onboardingCancelDiscord({
			...onboardingApiClientOptions(cookies),
		});
	}
	cookies.delete("_dhc_onboarding_acceptance", {
		path: `/members/signup/${params.invitationId}`,
	});
	throw redirect(303, `/members/signup/${params.invitationId}`);
};
