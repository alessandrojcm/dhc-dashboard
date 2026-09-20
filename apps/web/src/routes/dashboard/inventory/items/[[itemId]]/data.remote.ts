import { form, getRequestEvent } from "$app/server";
import {
	inventoryItemsChangeCategory,
	inventoryItemsCreate,
	inventoryItemsEndMaintenance,
	inventoryItemsMove,
	inventoryItemsStartMaintenance,
	inventoryItemsUpdate,
	vInventoryMaintenanceEndRequest,
	vInventoryMaintenanceStartRequest,
	vInventoryOperatorItemCreateRequest,
	vInventoryOperatorItemUpdateRequest,
} from "@dhc/api-client";
import { apiErrorMessage } from "$lib/api-error";
import { apiClientOptions } from "$lib/server/api-client";
import { authorize } from "$lib/server/auth";
import * as v from "valibot";

const uuid = v.pipe(v.string(), v.uuid("Choose a valid record"));
const identifier = v.pipe(v.string(), v.minLength(1, "An item is required"));
const itemCreateFields = vInventoryOperatorItemCreateRequest.entries;
const itemUpdateFields = vInventoryOperatorItemUpdateRequest.entries;
const maintenanceStartFields = vInventoryMaintenanceStartRequest.entries;
const maintenanceEndFields = vInventoryMaintenanceEndRequest.entries;
const nullableNotes = v.pipe(
	v.string(),
	v.transform((value) => value.trim()),
	v.transform((value) => value || null),
);
const jsonValues = v.pipe(
	v.string(),
	v.check((value) => {
		try {
			JSON.parse(value);
			return true;
		} catch {
			return false;
		}
	}, "Item properties are invalid"),
	// SAFETY: the preceding pipeline check proves this string is valid JSON;
	// the following record schema validates the parsed value's complete shape.
	v.transform((value) => JSON.parse(value) as unknown),
	v.record(uuid, v.nullable(v.union([v.string(), v.boolean(), v.number()]))),
);

const createItemSchema = v.object({
	categoryId: uuid,
	containerId: uuid,
	notes: v.pipe(nullableNotes, v.nullable(v.unwrap(itemCreateFields.notes))),
	values: jsonValues,
});
const updateItemSchema = v.object({
	slugOrId: identifier,
	notes: v.pipe(nullableNotes, v.nullable(v.unwrap(itemUpdateFields.notes))),
	values: jsonValues,
});
const moveItemSchema = v.object({ slugOrId: identifier, containerId: uuid });
const changeCategorySchema = v.object({
	slugOrId: identifier,
	categoryId: uuid,
	values: jsonValues,
});
const startMaintenanceSchema = v.object({
	slugOrId: identifier,
	reason: v.pipe(
		v.string(),
		v.transform((value) => value.trim()),
		maintenanceStartFields.reason,
	),
});
const endMaintenanceSchema = v.object({
	slugOrId: identifier,
	endNote: v.pipe(
		nullableNotes,
		v.nullable(v.unwrap(maintenanceEndFields.endNote)),
	),
});

function failure(cause: unknown, fallback: string) {
	return { ok: false as const, error: apiErrorMessage(cause, fallback) };
}

async function requestOptions() {
	const event = getRequestEvent();
	await authorize(event.locals, "inventory.manage");
	return apiClientOptions(event.cookies);
}

export const createItem = form(createItemSchema, async (body) => {
	const response = await inventoryItemsCreate({
		...(await requestOptions()),
		body,
	});
	if (response.error) return failure(response.error, "Could not create item");
	return { ok: true as const, data: response.data.data };
});

export const updateItem = form(
	updateItemSchema,
	async ({ slugOrId, ...body }) => {
		const response = await inventoryItemsUpdate({
			...(await requestOptions()),
			path: { slugOrId },
			body,
		});
		if (response.error) return failure(response.error, "Could not update item");
		return { ok: true as const, data: response.data.data };
	},
);

export const moveItem = form(
	moveItemSchema,
	async ({ slugOrId, ...fields }) => {
		const response = await inventoryItemsMove({
			...(await requestOptions()),
			path: { slugOrId },
			body: fields,
		});
		if (response.error) return failure(response.error, "Could not move item");
		return { ok: true as const, data: response.data.data };
	},
);

export const changeItemCategory = form(
	changeCategorySchema,
	async ({ slugOrId, ...body }) => {
		const response = await inventoryItemsChangeCategory({
			...(await requestOptions()),
			path: { slugOrId },
			body,
		});
		if (response.error)
			return failure(response.error, "Could not change category");
		return { ok: true as const, data: response.data.data };
	},
);

export const startItemMaintenance = form(
	startMaintenanceSchema,
	async ({ slugOrId, ...fields }) => {
		const response = await inventoryItemsStartMaintenance({
			...(await requestOptions()),
			path: { slugOrId },
			body: fields,
		});
		if (response.error)
			return failure(response.error, "Could not start maintenance");
		return { ok: true as const, data: response.data.data };
	},
);

export const endItemMaintenance = form(
	endMaintenanceSchema,
	async ({ slugOrId, ...fields }) => {
		const response = await inventoryItemsEndMaintenance({
			...(await requestOptions()),
			path: { slugOrId },
			body: fields,
		});
		if (response.error)
			return failure(response.error, "Could not end maintenance");
		return { ok: true as const, data: response.data.data };
	},
);
