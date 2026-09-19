import type { PageServerLoad } from "./$types";
import { consumeInvitationSignInPrefill } from "$lib/server/invitation-acceptance";

export const load: PageServerLoad = async ({ cookies }) => {
	return { prefillEmail: consumeInvitationSignInPrefill(cookies) };
};
