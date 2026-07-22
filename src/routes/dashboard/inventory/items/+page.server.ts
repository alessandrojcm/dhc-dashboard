import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { INVENTORY_ROLES } from "$lib/server/roles";
import {
	inventoryCategoriesIndex,
	inventoryContainersIndex,
} from "@dhc/api-client";

import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, cookies }) => {
	await authorize(locals, INVENTORY_ROLES);
	const [categoriesResponse, containersResponse] = await Promise.all([
		inventoryCategoriesIndex(apiClientOptions(cookies)),
		inventoryContainersIndex(apiClientOptions(cookies)),
	]);

	if (categoriesResponse.error) {
		throw new Error(
			categoriesResponse.error.errors?.detail ?? "Failed to load categories",
		);
	}
	if (containersResponse.error) {
		throw new Error(
			containersResponse.error.errors?.detail ?? "Failed to load containers",
		);
	}

	return {
		categories: categoriesResponse.data.data.categories.map((c) => ({
			id: c.id,
			name: c.name,
		})),
		containers: containersResponse.data.data.containers.map((c) => ({
			id: c.id,
			name: c.name,
		})),
	};
};
