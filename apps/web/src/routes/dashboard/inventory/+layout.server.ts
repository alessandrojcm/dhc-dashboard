import { error } from "@sveltejs/kit";
import { getRolesFromSession, INVENTORY_ROLES } from "$lib/server/roles";
import type { LayoutServerLoad } from "./$types";

export const load: LayoutServerLoad = async ({ locals }) => {
	const { session } = await locals.safeGetSession();
	const roles = getRolesFromSession(session);

	if (roles.intersection(INVENTORY_ROLES).size === 0) {
		error(
			403,
			"Inventory administration is restricted to inventory operators.",
		);
	}

	return {};
};
