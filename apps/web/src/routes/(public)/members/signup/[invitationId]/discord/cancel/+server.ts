import { onboardingCancelDiscord } from "@dhc/api-client";
import { redirect, type RequestHandler } from "@sveltejs/kit";
import {
	clearInvitationAcceptanceProof,
	hasInvitationAcceptanceProof,
	invitationAcceptanceApiOptions,
} from "$lib/server/invitation-acceptance-proof";

// Deliberately no continuation in this URL: the protected cookie is the only
// browser-held reference used to release the claim.
export const POST: RequestHandler = async ({ cookies, params }) => {
	try {
		if (hasInvitationAcceptanceProof(cookies)) {
			await onboardingCancelDiscord({
				...invitationAcceptanceApiOptions(cookies),
			});
		}
	} finally {
		clearInvitationAcceptanceProof(cookies);
	}
	throw redirect(303, `/members/signup/${params.invitationId}`);
};
