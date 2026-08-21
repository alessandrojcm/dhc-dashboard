import {
	onboardingRetryAcceptance,
	onboardingShowInvitationAcceptance,
} from "@dhc/api-client";
import { redirect } from "@sveltejs/kit";
import {
	clearInvitationAcceptanceProof,
	hasInvitationAcceptanceProof,
	invitationAcceptanceApiOptions,
} from "$lib/server/invitation-acceptance-proof";
import { completeInvitationAcceptance } from "$lib/server/post-acceptance-sign-in-handoff";
import type { PageServerLoad } from "./$types";

// The resume URL contains only the public invitation route parameter. The
// protected continuation remains in the HTTP-only cookie.
export const load: PageServerLoad = async ({ params, cookies }) => {
	if (hasInvitationAcceptanceProof(cookies)) {
		const current = await onboardingShowInvitationAcceptance({
			...invitationAcceptanceApiOptions(cookies),
		});

		if (current.data?.data?.state === "accepted") {
			completeInvitationAcceptance(
				cookies,
				current.data.data.invitationEmail,
				params.invitationId,
			);
		}
		if (
			current.data?.data?.state === "restart_verification" ||
			current.response?.status === 409
		) {
			clearInvitationAcceptanceProof(cookies);
		} else if (current.data?.data?.retryAllowed === true) {
			const retried = await onboardingRetryAcceptance({
				...invitationAcceptanceApiOptions(cookies),
			});

			if (retried.data?.data?.state === "accepted") {
				completeInvitationAcceptance(
					cookies,
					retried.data.data.invitationEmail,
					params.invitationId,
				);
			}
			if (retried.data?.data?.state === "restart_verification") {
				clearInvitationAcceptanceProof(cookies);
			}
		}
	}

	throw redirect(303, `/members/signup/${params.invitationId}`);
};
