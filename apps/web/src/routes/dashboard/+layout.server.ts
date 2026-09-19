import { authorizationFor } from "$lib/server/authorization";
import type { LayoutServerLoad } from "./$types";
import { invariant } from "$lib/server/invariant";

export const load: LayoutServerLoad = async ({ locals }) => {
	const { session } = await locals.safeGetSession();
	invariant(!session, "Unauthorized");

	// GH-510: the sidebar receives navigation already filtered by the same
	// capability decisions the route guard and route loads use.
	return {
		navData: authorizationFor(session).navigation(),
	};
};
