/**
 * Equipment Category management remote forms — ALE-105.
 *
 * These forms previously routed through the Kysely `CategoryService` (Supabase
 * RLS). They now POST/PATCH/DELETE through the generated `@dhc/api-client`
 * Phoenix endpoints (`inventoryCategoriesCreate` / `inventoryCategoriesUpdate`
 * / `inventoryCategoriesDelete`), carrying the user's Supabase JWT as the
 * bearer. The Phoenix `:inventory_admin_api` pipeline enforces the write-role
 * check (`quartermaster`/`president`/`admin`); `authorize()` is still called
 * here so the SvelteKit layer 403s before reaching the network when the role
 * is missing.
 *
 * The form schema (`categorySchema` from `$lib/schemas/inventory`) validates
 * the snake_case shape the UI/`AttributeBuilder` emits
 * (`available_attributes`, `default_value`). The OpenAPI contract uses
 * camelCase payload keys (`availableAttributes`, `defaultValue`); the
 * `toApiBody` helper performs that translation before calling the SDK.
 *
 * Reads (list/show) are consumed browser-side via `inventoryCategoriesIndex`
 * in `+page.svelte` / the edit load — see those files.
 */

import { form, getRequestEvent } from "$app/server";
import { redirect } from "@sveltejs/kit";
import * as v from "valibot";
import {
	inventoryCategoriesCreate,
	inventoryCategoriesDelete,
	inventoryCategoriesUpdate,
	type InventoryCategoryCreateRequest,
} from "@dhc/api-client";
import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { INVENTORY_ROLES } from "$lib/server/roles";
import { categorySchema } from "$lib/schemas/inventory";

type CategoryAttributeRequest =
	InventoryCategoryCreateRequest["availableAttributes"][number];

function toApiAttribute(
	attribute: v.InferOutput<
		typeof categorySchema
	>["available_attributes"][number],
): CategoryAttributeRequest {
	const converted: CategoryAttributeRequest = {
		type: attribute.type,
		label: attribute.label,
		required: attribute.required,
		options: attribute.options,
		name: attribute.name,
	};
	if (
		attribute.default_value !== undefined &&
		attribute.default_value !== null
	) {
		converted.defaultValue = attribute.default_value;
	}
	return converted;
}

/**
 * Translate a valibot-validated form payload (snake_case, the shape
 * `AttributeBuilder` emits) to the camelCase `InventoryCategoryCreateRequest`
 * the OpenAPI contract expects. Attribute-definition maps keep their other
 * keys (`name`/`label`/`type`/`required`/`options`); only `default_value`
 * becomes `defaultValue`.
 */
function toApiBody(
	data: v.InferOutput<typeof categorySchema>,
): InventoryCategoryCreateRequest {
	const body: InventoryCategoryCreateRequest = {
		name: data.name,
		availableAttributes: (data.available_attributes ?? []).map(toApiAttribute),
	};
	if (data.description) body.description = data.description;
	return body;
}

export const createCategory = form(categorySchema, async (data) => {
	const event = getRequestEvent();
	await authorize(event.locals, INVENTORY_ROLES);

	const response = await inventoryCategoriesCreate({
		...apiClientOptions(event.cookies),
		body: toApiBody(data),
	});

	if (response.error) {
		throw new Error(
			response.error.errors?.detail ??
				"Failed to create category. Please try again later.",
		);
	}

	redirect(303, "/dashboard/inventory/categories");
});

export const updateCategory = form(categorySchema, async (data) => {
	const event = getRequestEvent();
	const categoryId = event.params.id;
	await authorize(event.locals, INVENTORY_ROLES);
	if (!categoryId) throw new Error("Category ID is required");

	const response = await inventoryCategoriesUpdate({
		...apiClientOptions(event.cookies),
		path: { id: categoryId },
		body: toApiBody(data),
	});

	if (response.error) {
		throw new Error(
			response.error.errors?.detail ??
				"Failed to update category. Please try again later.",
		);
	}

	redirect(303, "/dashboard/inventory/categories");
});

export const deleteCategory = form(v.object({}), async () => {
	const event = getRequestEvent();
	const categoryId = event.params.id;
	await authorize(event.locals, INVENTORY_ROLES);
	if (!categoryId) throw new Error("Category ID is required");

	const response = await inventoryCategoriesDelete({
		...apiClientOptions(event.cookies),
		path: { id: categoryId },
	});

	if (response.error) {
		throw new Error(
			response.error.errors?.detail ??
				"Failed to delete category. Please try again later.",
		);
	}

	redirect(303, "/dashboard/inventory/categories");
});
