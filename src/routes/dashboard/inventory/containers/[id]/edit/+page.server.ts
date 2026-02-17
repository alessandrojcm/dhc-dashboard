import { error } from "@sveltejs/kit";
import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import { createContainerService } from "$lib/server/services/inventory";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ params, locals, platform }) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const containerService = createContainerService(platform!, session);

	// Get container by ID
	const container = await containerService.findById(params.id);

	if (!container) {
		throw error(404, "Container not found");
	}

	// Get available parent containers (excluding self and descendants)
	const availableContainers = await containerService.getAvailableParents(
		params.id,
	);

	return {
		containerData: {
			name: container.name,
			description: container.description || "",
			parent_container_id: container.parent_container_id || "",
		},
		containers: availableContainers,
		container,
	};
};
