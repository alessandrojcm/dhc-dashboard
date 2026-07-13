import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { INVENTORY_ROLES } from "$lib/server/roles";
import {
	inventoryCategoriesIndex,
	inventoryContainersIndex,
} from "@dhc/api-client";
import type { PageServerLoad } from "./$types";

function toLegacyCategory(c: any) {
	return {
		id: c.id,
		name: c.name,
		description: c.description ?? null,
		available_attributes: (c.availableAttributes ?? []).map((attr: any) => {
			const { defaultValue, ...rest } = attr;
			return {
				...rest,
				...(defaultValue !== undefined ? { default_value: defaultValue } : {}),
			};
		}),
	};
}

export const load: PageServerLoad = async ({ url, locals }) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const preselectedContainer = url.searchParams.get("container");
	const preselectedCategory = url.searchParams.get("category");

	const [categoriesResponse, containersResponse] = await Promise.all([
		inventoryCategoriesIndex(apiClientOptions(session)),
		inventoryContainersIndex(apiClientOptions(session)),
	]);

	if (categoriesResponse.error) throw new Error("Failed to load categories");
	if (containersResponse.error) throw new Error("Failed to load containers");

	return {
		initialData: {
			container_id: preselectedContainer || "",
			category_id: preselectedCategory || "",
			attributes: {} as Record<string, unknown>,
			quantity: 1,
			notes: "",
			out_for_maintenance: false,
		},
		categories: categoriesResponse.data.data.categories.map(toLegacyCategory),
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
