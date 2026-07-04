import { error } from "@sveltejs/kit";
import { inventoryCategoriesShow } from "@dhc/api-client";
import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { INVENTORY_ROLES } from "$lib/server/roles";
import type { PageServerLoadEvent } from "./$types";
import type { AttributeDefinition } from "$lib/schemas/inventory";

export const load = async ({ params, locals }: PageServerLoadEvent) => {
	const session = await authorize(locals, INVENTORY_ROLES);

	const response = await inventoryCategoriesShow({
		...apiClientOptions(session),
		path: { id: params.id },
	});

	if (response.error) {
		// 404 → SvelteKit not-found page; anything else surfaces as a 500.
		if (response.response?.status === 404) {
			throw error(404, "Category not found");
		}
		throw error(
			500,
			response.error.errors?.detail ?? "Failed to load category",
		);
	}

	// `response.data` is the `InventoryCategoryResponse` envelope `{ data: ... }`.
	const category = response.data.data;

	// The form/AttributeBuilder consume the snake_case shape; the API returns
	// camelCase (`availableAttributes`, `defaultValue`). Map back so the
	// existing edit UI keeps working unchanged.
	const available_attributes: AttributeDefinition[] = (
		category.availableAttributes ?? []
	).map((attr) => {
		const { defaultValue, ...rest } = attr;
		return {
			...rest,
			...(defaultValue !== undefined ? { default_value: defaultValue } : {}),
		} as AttributeDefinition;
	});

	return {
		category: {
			id: category.id,
			name: category.name,
			description: category.description ?? "",
			available_attributes,
		},
	};
};
