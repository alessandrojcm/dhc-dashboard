import { onboardingRetryAcceptance } from "@dhc/api-client";
import { redirect } from "@sveltejs/kit";
import { apiBaseUrl } from "$lib/server/api-client";
import type { PageServerLoad } from "./$types";

// The resume URL contains only the public invitation route parameter. The
// protected continuation remains in the HTTP-only cookie.
export const load: PageServerLoad = async ({ params, cookies }) => {
	const proof = cookies.get(`onboarding-acceptance-${params.invitationId}`);

	if (proof) {
		const response = await onboardingRetryAcceptance({
			baseUrl: apiBaseUrl(),
			headers: { "x-onboarding-continuation": proof },
		});

		if (response.data?.data?.state === "accepted") {
			cookies.delete(`onboarding-acceptance-${params.invitationId}`, {
				path: "/",
			});
			throw redirect(303, `/members/signup/${params.invitationId}/success`);
		}
	}

	throw redirect(303, `/members/signup/${params.invitationId}`);
};
