import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import type { PageServerLoadEvent } from "./$types";

export const load = async ({ locals }: PageServerLoadEvent) => {
	await authorize(locals, INVENTORY_ROLES);

	return {};
};
