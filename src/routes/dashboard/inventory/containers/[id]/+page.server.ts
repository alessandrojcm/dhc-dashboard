import { error } from "@sveltejs/kit";
import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import { createContainerService } from "$lib/server/services/inventory";
import type { PageServerLoadEvent } from "./$types";

export const load = async ({
	params,
	locals,
	parent,
	platform,
}: PageServerLoadEvent) => {
	const { canEdit } = await parent();
	const session = await authorize(locals, INVENTORY_ROLES);

	const containerService = createContainerService(platform!, session);

	// Get container with all relations
	const container = await containerService.getWithRelations(params.id);

	if (!container) {
		throw error(404, "Container not found");
	}

	return {
		container,
		canEdit,
	};
};
