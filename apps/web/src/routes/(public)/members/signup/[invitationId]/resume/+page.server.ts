import { onboardingRetryAcceptance } from "@dhc/api-client";
import { redirect } from "@sveltejs/kit";
import { dev } from "$app/environment";
import {
	onboardingAcceptanceCookie,
	onboardingApiClientOptions,
} from "$lib/server/onboarding-api";
import type { PageServerLoad } from "./$types";

// The resume URL contains only the public invitation route parameter. The
// protected continuation remains in the HTTP-only cookie.
export const load: PageServerLoad = async ({ params, cookies }) => {
	const proof = cookies.get(onboardingAcceptanceCookie);

	if (proof) {
		const response = await onboardingRetryAcceptance({
			...onboardingApiClientOptions(cookies),
		});

		if (response.data?.data?.state === "accepted") {
			if (response.data.data.invitationEmail) {
				cookies.set(
					"invitation-sign-in-prefill",
					response.data.data.invitationEmail,
					{
						path: "/auth",
						httpOnly: true,
						secure: !dev,
						sameSite: "lax",
						maxAge: 10 * 60,
					},
				);
			}
			cookies.delete(onboardingAcceptanceCookie, {
				path: `/members/signup/${params.invitationId}`,
			});
			throw redirect(303, `/members/signup/${params.invitationId}/success`);
		}
	}

	throw redirect(303, `/members/signup/${params.invitationId}`);
};
