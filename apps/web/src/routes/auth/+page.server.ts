import type { PageServerLoad } from "./$types";
import { consumeInvitationSignInPrefill } from "#lib/server/invitation-acceptance/index.js";

export const load: PageServerLoad = async ({ cookies }) => {
	return { prefillEmail: consumeInvitationSignInPrefill(cookies) };
};
