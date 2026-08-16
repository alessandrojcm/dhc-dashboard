/**
 * Inventory Item management remote forms — ALE-107 + ALE-108.
 *
 * These forms previously routed through the Kysely `ItemService` (Supabase
 * RLS). They now POST/PATCH through the generated `@dhc/api-client` Phoenix
 * endpoints (`inventoryItemsCreate` / `inventoryItemsUpdate`), carrying the
 * user's Supabase JWT as the bearer. The Phoenix `:inventory_admin_api`
 * pipeline enforces the write-role check (`quartermaster`/`president`/`admin`);
 * `authorize()` is still called here so the SvelteKit layer 403s before
 * reaching the network when the role is missing.
 *
 * ALE-108 adds dedicated `moveItem` and `setMaintenance` commands that hit
 * `POST /inventory/items/{id}/move` and `POST /inventory/items/{id}/maintenance`,
 * preserving the `moved` / `maintenance_out` / `maintenance_in` audit history
 * side effects as required by the Inventory REST contract.
 */

import { command, form, getRequestEvent } from "$app/server";
import { redirect } from "@sveltejs/kit";
import * as v from "valibot";
import {
	inventoryItemsCreate,
	inventoryItemsMaintenance,
	inventoryItemsMove,
	inventoryItemsUpdate,
	type InventoryItemCreateRequest,
	type InventoryItemMaintenanceRequest,
	type InventoryItemMoveRequest,
} from "@dhc/api-client";
import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { INVENTORY_ROLES } from "$lib/server/roles";
import { inventoryAttributesSchema, itemSchema } from "$lib/schemas/inventory";

type ItemFormData = v.InferOutput<typeof itemSchema>;

function normalizeAttributes(cause: unknown): ItemFormData["attributes"] {
	const attributes = v.safeParse(inventoryAttributesSchema, cause);
	if (attributes.success) return attributes.output;

	const serialized = v.safeParse(v.string(), cause);
	if (serialized.success) {
		try {
			const parsed = v.safeParse(
				inventoryAttributesSchema,
				JSON.parse(serialized.output),
			);
			return parsed.success ? parsed.output : {};
		} catch {
			return {};
		}
	}
	return {};
}

function toApiBody(data: ItemFormData): InventoryItemCreateRequest {
	const body: InventoryItemCreateRequest = {
		containerId: data.container_id,
		categoryId: data.category_id,
		quantity: data.quantity,
		attributes: normalizeAttributes(data.attributes),
	};
	if (data.notes) body.notes = data.notes;
	if (data.out_for_maintenance !== undefined) {
		body.outForMaintenance = data.out_for_maintenance;
	}
	return body;
}

export const createItem = form(itemSchema, async (data) => {
	const event = getRequestEvent();
	await authorize(event.locals, INVENTORY_ROLES);

	const response = await inventoryItemsCreate({
		...apiClientOptions(event.cookies),
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

export const updateItem = form(itemSchema, async (data) => {
	const event = getRequestEvent();
	await authorize(event.locals, INVENTORY_ROLES);
	const itemId = event.params.id;
	if (!itemId) throw new Error("Item ID is required");

	const response = await inventoryItemsUpdate({
		...apiClientOptions(event.cookies),
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

// ── ALE-108: dedicated movement/maintenance command endpoints ─────────
// These preserve the moved / maintenance_out / maintenance_in audit history
// side effects as dedicated commands, separate from the general PATCH update.

const MoveItemSchema = v.object({
	containerId: v.pipe(v.string(), v.uuid()),
	notes: v.optional(v.pipe(v.string(), v.maxLength(1000))),
});

const MaintenanceItemSchema = v.object({
	outForMaintenance: v.boolean(),
	notes: v.optional(v.pipe(v.string(), v.maxLength(1000))),
});

export const moveItem = command(MoveItemSchema, async (input) => {
	const event = getRequestEvent();
	await authorize(event.locals, INVENTORY_ROLES);
	const itemId = event.params.id;
	if (!itemId) throw new Error("Item ID is required");
	const body: InventoryItemMoveRequest = { containerId: input.containerId };
	if (input.notes) body.notes = input.notes;

	const response = await inventoryItemsMove({
		...apiClientOptions(event.cookies),
		path: { id: itemId },
		body,
	});

	if (response.error) {
		throw new Error(
			response.error.errors?.detail ??
				"Failed to move item. Please try again later.",
		);
	}

	return { success: "Item moved successfully" };
});

export const setMaintenance = command(MaintenanceItemSchema, async (input) => {
	const event = getRequestEvent();
	await authorize(event.locals, INVENTORY_ROLES);
	const itemId = event.params.id;
	if (!itemId) throw new Error("Item ID is required");
	const body: InventoryItemMaintenanceRequest = {
		outForMaintenance: input.outForMaintenance,
	};
	if (input.notes) body.notes = input.notes;

	const response = await inventoryItemsMaintenance({
		...apiClientOptions(event.cookies),
		path: { id: itemId },
		body,
	});

	if (response.error) {
		throw new Error(
			response.error.errors?.detail ??
				"Failed to update maintenance status. Please try again later.",
		);
	}

	return { success: "Maintenance status updated successfully" };
});
