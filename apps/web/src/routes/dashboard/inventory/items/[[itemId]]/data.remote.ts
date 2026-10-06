import { form } from "$app/server";
import {
	inventoryItemsChangeCategory,
	inventoryItemsCreate,
	inventoryItemsEndMaintenance,
	inventoryItemsMove,
	inventoryItemsShow,
	inventoryItemsStartMaintenance,
	inventoryItemsUpdate,
	inventoryStructureListDefinitions,
	vInventoryMaintenanceEndRequest,
	vInventoryMaintenanceStartRequest,
	vInventoryOperatorItemCreateRequest,
	vInventoryOperatorItemUpdateRequest,
} from "@dhc/api-client";
import { inventoryCommand } from "#lib/server/api/inventory-command.js";
import {
	type InventoryManageOptions,
	inventoryManageOptions,
} from "#lib/server/api/inventory-manage-options.js";
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

/** Labels of the category's Property Definitions, for value rejections. */
function categoryPropertyLabels(
	options: InventoryManageOptions,
	categoryId: string,
) {
	return async () => {
		const response = await inventoryStructureListDefinitions({
			...options,
			path: { categoryId },
		});
		const definitions = response.data?.data.definitions ?? [];
		return new Map(
			definitions.map((definition) => [definition.id, definition.label]),
		);
	};
}

/** The item's current category's labels, for an update that keeps it. */
function itemPropertyLabels(options: InventoryManageOptions, slugOrId: string) {
	return async () => {
		const response = await inventoryItemsShow({
			...options,
			path: { slugOrId },
		});
		if (!response.data) return new Map<string, string>();
		return categoryPropertyLabels(options, response.data.data.categoryId)();
	};
}

export const createItem = form(createItemSchema, async (body, issue) => {
	const options = await inventoryManageOptions();
	return inventoryCommand(inventoryItemsCreate({ ...options, body }), {
		fallback: "Could not create item",
		fields: ["categoryId", "containerId", "notes", "values"],
		issue,
		propertyLabels: categoryPropertyLabels(options, body.categoryId),
	});
});

export const updateItem = form(
	updateItemSchema,
	async ({ slugOrId, ...body }, issue) => {
		const options = await inventoryManageOptions();
		return inventoryCommand(
			inventoryItemsUpdate({ ...options, path: { slugOrId }, body }),
			{
				fallback: "Could not update item",
				fields: ["notes", "values"],
				issue,
				propertyLabels: itemPropertyLabels(options, slugOrId),
			},
		);
	},
);

export const moveItem = form(
	moveItemSchema,
	async ({ slugOrId, ...fields }, issue) =>
		inventoryCommand(
			inventoryItemsMove({
				...(await inventoryManageOptions()),
				path: { slugOrId },
				body: fields,
			}),
			{ fallback: "Could not move item", fields: ["containerId"], issue },
		),
);

export const changeItemCategory = form(
	changeCategorySchema,
	async ({ slugOrId, ...body }, issue) => {
		const options = await inventoryManageOptions();
		return inventoryCommand(
			inventoryItemsChangeCategory({ ...options, path: { slugOrId }, body }),
			{
				fallback: "Could not change category",
				fields: ["categoryId", "values"],
				issue,
				propertyLabels: categoryPropertyLabels(options, body.categoryId),
			},
		);
	},
);

export const startItemMaintenance = form(
	startMaintenanceSchema,
	async ({ slugOrId, ...fields }, issue) =>
		inventoryCommand(
			inventoryItemsStartMaintenance({
				...(await inventoryManageOptions()),
				path: { slugOrId },
				body: fields,
			}),
			{ fallback: "Could not start maintenance", fields: ["reason"], issue },
		),
);

export const endItemMaintenance = form(
	endMaintenanceSchema,
	async ({ slugOrId, ...fields }, issue) =>
		inventoryCommand(
			inventoryItemsEndMaintenance({
				...(await inventoryManageOptions()),
				path: { slugOrId },
				body: fields,
			}),
			{ fallback: "Could not end maintenance", fields: ["endNote"], issue },
		),
);
