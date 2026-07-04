import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import { apiClientOptions } from "$lib/server/api-client";
import { inventoryContainersIndex } from "@dhc/api-client";
import type { PageServerLoadEvent } from "./$types";

// The create page builds a parent-select hierarchy from a flat container list
// (snake_case shape, the legacy `ContainerService.findMany()` output the UI
// expects). ALE-106 switches the source to the Phoenix
// `inventoryContainersIndex` endpoint and maps the camelCase API payload back
// to that snake_case shape so the page template is unchanged.
export const load = async ({ locals }: PageServerLoadEvent) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const response = await inventoryContainersIndex(apiClientOptions(session));

	if (response.error) {
		throw new Error(
			response.error.errors?.detail ?? "Failed to load containers",
		);
	}

	const containers = response.data.data.containers.map((c) => ({
		id: c.id,
		name: c.name,
		description: c.description ?? null,
		parent_container_id: c.parentContainerId ?? null,
	}));

	return {
		containers,
	};
};
