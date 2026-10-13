import { form } from "$app/server";
import {
	inventoryItemsArchive,
	inventoryItemsChangeCategory,
	inventoryItemsCreate,
	inventoryItemsDelete,
	inventoryItemsEndMaintenance,
	inventoryItemsMove,
	inventoryItemsRestore,
	inventoryItemsShow,
	inventoryItemsStartMaintenance,
	inventoryItemsUpdate,
	inventoryStructureListDefinitions,
} from "@dhc/api-client";
import {
	archiveItemSchema,
	changeItemCategorySchema,
	createItemSchema,
	deleteItemSchema,
	endItemMaintenanceSchema,
	moveItemSchema,
	restoreItemSchema,
	startItemMaintenanceSchema,
	updateItemSchema,
} from "#lib/schemas/inventoryItem.js";
import { inventoryCommand } from "#lib/server/api/inventory-command.js";
import {
	type InventoryManageOptions,
	inventoryManageOptions,
} from "#lib/server/api/inventory-manage-options.js";

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

export const createItem = form(createItemSchema, async ({ body }, issue) => {
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
	async ({ slugOrId, body }, issue) => {
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
	async ({ slugOrId, body }, issue) =>
		inventoryCommand(
			inventoryItemsMove({
				...(await inventoryManageOptions()),
				path: { slugOrId },
				body,
			}),
			{ fallback: "Could not move item", fields: ["containerId"], issue },
		),
);

export const changeItemCategory = form(
	changeItemCategorySchema,
	async ({ slugOrId, body }, issue) => {
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
	startItemMaintenanceSchema,
	async ({ slugOrId, body }, issue) =>
		inventoryCommand(
			inventoryItemsStartMaintenance({
				...(await inventoryManageOptions()),
				path: { slugOrId },
				body,
			}),
			{ fallback: "Could not start maintenance", fields: ["reason"], issue },
		),
);

export const endItemMaintenance = form(
	endItemMaintenanceSchema,
	async ({ slugOrId, body }, issue) =>
		inventoryCommand(
			inventoryItemsEndMaintenance({
				...(await inventoryManageOptions()),
				path: { slugOrId },
				body,
			}),
			{ fallback: "Could not end maintenance", fields: ["endNote"], issue },
		),
);

export const archiveItem = form(
	archiveItemSchema,
	async ({ slugOrId, body }, issue) =>
		inventoryCommand(
			inventoryItemsArchive({
				...(await inventoryManageOptions()),
				path: { slugOrId },
				body,
			}),
			{ fallback: "Could not archive item", fields: ["reason"], issue },
		),
);

export const restoreItem = form(
	restoreItemSchema,
	async ({ slugOrId }, issue) =>
		inventoryCommand(
			inventoryItemsRestore({
				...(await inventoryManageOptions()),
				path: { slugOrId },
			}),
			{ fallback: "Could not restore item", fields: [], issue },
		),
);

export const deleteItem = form(
	deleteItemSchema,
	async ({ slugOrId, body }, issue) =>
		inventoryCommand(
			inventoryItemsDelete({
				...(await inventoryManageOptions()),
				path: { slugOrId },
				body,
			}),
			{
				fallback: "Items with history must be archived",
				fields: [],
				issue,
			},
		),
);
