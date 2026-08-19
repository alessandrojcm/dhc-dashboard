import { onboardingRetryAcceptance } from "@dhc/api-client";
import { redirect } from "@sveltejs/kit";
import { dev } from "$app/environment";
import {
	clearInvitationAcceptanceProof,
	hasInvitationAcceptanceProof,
	invitationAcceptanceApiOptions,
} from "$lib/server/invitation-acceptance-proof";
import type { PageServerLoad } from "./$types";

// The resume URL contains only the public invitation route parameter. The
// protected continuation remains in the HTTP-only cookie.
export const load: PageServerLoad = async ({ params, cookies }) => {
	if (hasInvitationAcceptanceProof(cookies)) {
		const response = await onboardingRetryAcceptance({
			...invitationAcceptanceApiOptions(cookies),
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
			clearInvitationAcceptanceProof(cookies);
			throw redirect(303, `/members/signup/${params.invitationId}/success`);
		}
		if (
			response.data?.data?.state === "restart_verification" ||
			response.response?.status === 409
		) {
			clearInvitationAcceptanceProof(cookies);
		}
	}

	throw redirect(303, `/members/signup/${params.invitationId}`);
};
