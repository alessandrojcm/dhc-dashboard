import {
	applyInvitationRouteOutcome,
	invitationAcceptanceDeps,
	readInvitationPage,
} from "#lib/server/invitation-acceptance/index.js";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ params, cookies }) => {
	const deps = invitationAcceptanceDeps(cookies);
	return applyInvitationRouteOutcome(await readInvitationPage(deps), {
		cookies: deps.cookies,
		invitationId: params.invitationId,
		mode: "render",
	});
};
