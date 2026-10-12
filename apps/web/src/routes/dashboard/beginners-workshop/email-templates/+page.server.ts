import { authorizationFor } from "#lib/server/authorization/index.js";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals }) => {
	const { session } = await locals.safeGetSession();
	authorizationFor(session).require("beginners.workshops.manage");
};
