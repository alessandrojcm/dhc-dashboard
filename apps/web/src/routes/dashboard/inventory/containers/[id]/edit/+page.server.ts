import { error } from "@sveltejs/kit";
import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import { apiClientOptions } from "$lib/server/api-client";
import {
	inventoryContainersIndex,
	inventoryContainersShow,
} from "@dhc/api-client";
import type { PageServerLoad } from "./$types";

// The edit page consumes the legacy `findById` + `getAvailableParents`
// snake_case shapes: `containerData` (`{name, description,
// parent_container_id}`), a flat `containers` list for the parent-select
// (the page filters descendants client-side to preserve circular-parent
// prevention), and a `container` row (used for its id + back-link). ALE-106
// switches the source to the Phoenix `inventoryContainersShow` +
// `inventoryContainersIndex` endpoints and maps the camelCase API payloads
// back to those snake_case shapes so the page template is unchanged.
export const load: PageServerLoad = async ({ params, locals, cookies }) => {
	await authorize(locals, INVENTORY_ROLES);

	const showResponse = await inventoryContainersShow({
		...apiClientOptions(cookies),
		path: { id: params.id },
	});

	if (showResponse.error) {
		if (showResponse.response?.status === 404) {
			throw error(404, "Container not found");
		}
		throw error(
			500,
			showResponse.error.errors?.detail ?? "Failed to load container",
		);
	}

	const detail = showResponse.data.data;

	const listResponse = await inventoryContainersIndex(
		apiClientOptions(cookies),
	);

	if (listResponse.error) {
		throw new Error(
			listResponse.error.errors?.detail ?? "Failed to load containers",
		);
	}

	const containers = listResponse.data.data.containers.map((c) => ({
		id: c.id,
		name: c.name,
		description: c.description ?? null,
		parent_container_id: c.parentContainerId ?? null,
	}));

	return {
		containerData: {
			name: detail.name,
			description: detail.description ?? "",
			parent_container_id: detail.parentContainerId ?? "",
		},
		containers,
		container: {
			id: detail.id,
			name: detail.name,
			description: detail.description ?? null,
			parent_container_id: detail.parentContainerId ?? null,
		},
	};
};
