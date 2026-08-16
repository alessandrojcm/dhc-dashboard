import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { INVENTORY_ROLES } from "$lib/server/roles";
import {
	inventoryCategoriesIndex,
	inventoryContainersIndex,
} from "@dhc/api-client";
import type { PageServerLoad } from "./$types";
import { parseLegacyInventoryCategory } from "$lib/schemas/inventory";

export const load: PageServerLoad = async ({ url, locals, cookies }) => {
	await authorize(locals, INVENTORY_ROLES);
	const preselectedContainer = url.searchParams.get("container");
	const preselectedCategory = url.searchParams.get("category");

	const [categoriesResponse, containersResponse] = await Promise.all([
		inventoryCategoriesIndex(apiClientOptions(cookies)),
		inventoryContainersIndex(apiClientOptions(cookies)),
	]);

	if (categoriesResponse.error) throw new Error("Failed to load categories");
	if (containersResponse.error) throw new Error("Failed to load containers");

	return {
		initialData: {
			container_id: preselectedContainer || "",
			category_id: preselectedCategory || "",
			attributes: {},
			quantity: 1,
			notes: "",
			out_for_maintenance: false,
		},
		categories: categoriesResponse.data.data.categories.map(
			parseLegacyInventoryCategory,
		),
		containers: containersResponse.data.data.containers.map((c) => ({
			id: c.id,
			name: c.name,
			description: c.description ?? null,
			parent_container_id: c.parentContainerId ?? null,
			created_by: "",
			created_at: c.createdAt ?? null,
			updated_at: c.updatedAt ?? null,
		})),
	};
};
