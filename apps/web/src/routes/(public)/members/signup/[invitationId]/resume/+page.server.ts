import { onboardingRetryAcceptance } from "@dhc/api-client";
import { redirect } from "@sveltejs/kit";
import { onboardingApiClientOptions } from "$lib/server/onboarding-api";
import type { PageServerLoad } from "./$types";

// The resume URL contains only the public invitation route parameter. The
// protected continuation remains in the HTTP-only cookie.
export const load: PageServerLoad = async ({ params, cookies }) => {
	const proof = cookies.get("_dhc_onboarding_acceptance");

	if (proof) {
		const response = await onboardingRetryAcceptance({
			...onboardingApiClientOptions(cookies),
		});

		if (response.data?.data?.state === "accepted") {
			cookies.delete("_dhc_onboarding_acceptance", {
				path: `/members/signup/${params.invitationId}`,
			});
			throw redirect(303, `/members/signup/${params.invitationId}/success`);
		}
	}

	throw redirect(303, `/members/signup/${params.invitationId}`);
};
