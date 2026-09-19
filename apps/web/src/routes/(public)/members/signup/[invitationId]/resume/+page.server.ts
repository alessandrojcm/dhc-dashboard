import {
	applyInvitationRouteOutcome,
	invitationAcceptanceDeps,
	resumeInvitationAcceptance,
} from "$lib/server/invitation-acceptance";
import type { PageServerLoad } from "./$types";

// The resume URL contains only the public invitation route parameter. The
// protected continuation remains in the HTTP-only cookie; the workflow decides
// whether to retry and where the browser goes next.
export const load: PageServerLoad = async ({ params, cookies }) => {
	const deps = invitationAcceptanceDeps(cookies);
	applyInvitationRouteOutcome(await resumeInvitationAcceptance(deps), {
		cookies: deps.cookies,
		invitationId: params.invitationId,
		mode: "redirect",
	});
};
