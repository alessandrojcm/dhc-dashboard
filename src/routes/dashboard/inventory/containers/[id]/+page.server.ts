import { error } from "@sveltejs/kit";
import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import { apiClientOptions } from "$lib/server/api-client";
import { inventoryContainersShow } from "@dhc/api-client";
import type { PageServerLoadEvent } from "./$types";

// The detail page consumes the legacy `getWithRelations` snake_case shape
// (`parent_container`, `child_containers`, `items` with a `category` summary).
// ALE-106 switches the source to the Phoenix `inventoryContainersShow`
// endpoint and maps the camelCase API payload back to that snake_case shape
// so the page template is unchanged. Item `attributes` are intentionally not
// part of the container-detail contract (ALE-104); the page's display helper
// falls back to `category.name` + id suffix when `attributes` is absent.
export const load = async ({ params, locals, parent }: PageServerLoadEvent) => {
	const { canEdit } = await parent();
	const session = await authorize(locals, INVENTORY_ROLES);

	const response = await inventoryContainersShow({
		...apiClientOptions(session),
		path: { id: params.id },
	});

	if (response.error) {
		// 404 → SvelteKit not-found page; anything else surfaces as a 500.
		if (response.response?.status === 404) {
			throw error(404, "Container not found");
		}
		throw error(
			500,
			response.error.errors?.detail ?? "Failed to load container",
		);
	}

	const detail = response.data.data;

	const container = {
		id: detail.id,
		name: detail.name,
		description: detail.description ?? null,
		parent_container_id: detail.parentContainerId ?? null,
		created_at: detail.createdAt,
		updated_at: detail.updatedAt,
		parent_container: detail.parentContainer
			? { id: detail.parentContainer.id, name: detail.parentContainer.name }
			: null,
		child_containers: (detail.childContainers ?? []).map((c) => ({
			id: c.id,
			name: c.name,
		})),
		items: (detail.items ?? []).map((item) => ({
			id: item.id,
			quantity: item.quantity,
			out_for_maintenance: item.outForMaintenance,
			category: item.category
				? { id: item.category.id, name: item.category.name }
				: null,
		})),
	};

	return {
		container,
		canEdit,
	};
};
