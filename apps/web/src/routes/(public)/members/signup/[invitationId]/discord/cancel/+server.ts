import type { RequestHandler } from "@sveltejs/kit";
import {
	applyInvitationRouteOutcome,
	invitationAcceptanceDeps,
	restartDiscordVerification,
} from "$lib/server/invitation-acceptance";

// Deliberately no continuation in this URL: the protected cookie is the only
// browser-held reference used to release the claim.
export const POST: RequestHandler = async ({ cookies, params }) => {
	const deps = invitationAcceptanceDeps(cookies);
	applyInvitationRouteOutcome(await restartDiscordVerification(deps), {
		cookies: deps.cookies,
		invitationId: params.invitationId ?? "",
		mode: "redirect",
	});
};
