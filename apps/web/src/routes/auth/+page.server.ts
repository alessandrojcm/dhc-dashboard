import type { PageServerLoad } from "./$types";
import { consumeInvitationSignInPrefill } from "$lib/server/post-acceptance-sign-in-handoff";

export const load: PageServerLoad = async ({ cookies }) => {
	return { prefillEmail: consumeInvitationSignInPrefill(cookies) };
};
