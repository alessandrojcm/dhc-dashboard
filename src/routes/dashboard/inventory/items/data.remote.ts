/**
 * Inventory Item management remote forms — ALE-107.
 *
 * These forms previously routed through the Kysely `ItemService` (Supabase
 * RLS). They now POST/PATCH through the generated `@dhc/api-client` Phoenix
 * endpoints (`inventoryItemsCreate` / `inventoryItemsUpdate`), carrying the
 * user's Supabase JWT as the bearer. The Phoenix `:inventory_admin_api`
 * pipeline enforces the write-role check (`quartermaster`/`president`/`admin`);
 * `authorize()` is still called here so the SvelteKit layer 403s before
 * reaching the network when the role is missing.
 */

import { form, getRequestEvent } from "$app/server";
import { redirect } from "@sveltejs/kit";
import * as v from "valibot";
import {
	inventoryItemsCreate,
	inventoryItemsUpdate,
	type InventoryItemCreateRequest,
} from "@dhc/api-client";
import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { INVENTORY_ROLES } from "$lib/server/roles";
import { itemSchema } from "$lib/schemas/inventory";

export const ItemCreateSchema = itemSchema;
export const ItemUpdateSchema = itemSchema;

type ItemFormData = v.InferOutput<typeof itemSchema>;

function normalizeAttributes(value: unknown): Record<string, unknown> {
	if (typeof value === "string") {
		try {
			const parsed = JSON.parse(value);
			return parsed && typeof parsed === "object" && !Array.isArray(parsed)
				? (parsed as Record<string, unknown>)
				: {};
		} catch {
			return {};
		}
	}

	return value && typeof value === "object" && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: {};
}

function toApiBody(data: ItemFormData): InventoryItemCreateRequest {
	return {
		containerId: data.container_id,
		categoryId: data.category_id,
		quantity: data.quantity,
		attributes: normalizeAttributes(data.attributes),
		...(data.notes ? { notes: data.notes } : {}),
		...(data.out_for_maintenance !== undefined
			? { outForMaintenance: data.out_for_maintenance }
			: {}),
	};
}

export const createItem = form(ItemCreateSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, INVENTORY_ROLES);

	const response = await inventoryItemsCreate({
		...apiClientOptions(session),
		body: toApiBody(data),
	});

	if (response.error) {
		throw new Error(
			response.error.errors?.detail ??
				"Failed to create item. Please try again later.",
		);
	}

	redirect(303, `/dashboard/inventory/items/${response.data.data.id}`);
});

export const updateItem = form(ItemUpdateSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, INVENTORY_ROLES);
	const itemId = event.params.id!;

	const response = await inventoryItemsUpdate({
		...apiClientOptions(session),
		path: { id: itemId },
		body: toApiBody(data),
	});

	if (response.error) {
		throw new Error(
			response.error.errors?.detail ??
				"Failed to update item. Please try again later.",
		);
	}

	return { success: "Item updated successfully" };
});
