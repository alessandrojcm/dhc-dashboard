import { authorizationFor } from "$lib/server/authorization";
import type { LayoutServerLoad } from "./$types";

export const load: LayoutServerLoad = async ({ locals }) => {
	const { session } = await locals.safeGetSession();
	// GH-510: same rule as the "Inventory" navigation entry and the request
	// hook; here it surfaces as a 403 rather than the hook's redirect.
	authorizationFor(session).require("inventory.manage");

	return {};
};
