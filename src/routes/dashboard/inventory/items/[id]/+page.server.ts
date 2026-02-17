import { error } from "@sveltejs/kit";
import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import {
	createItemService,
	createHistoryService,
} from "$lib/server/services/inventory";
import type {
	InventoryAttributeDefinition,
	InventoryAttributes,
} from "$lib/types";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ params, locals, platform }) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const itemService = createItemService(platform!, session);
	const historyService = createHistoryService(platform!, session);

	// Get item with relations
	const item = await itemService.findById(params.id);

	if (!item) {
		throw error(404, "Item not found");
	}

	// Get history for the item
	const [history, filterOptions] = await Promise.all([
		historyService.getByItem(params.id, 20),
		itemService.getFilterOptions(),
	]);

	// Initialize all category attributes, preserving existing values
	const initialAttributes: InventoryAttributes = {};
	const existingAttributes = (item.attributes as InventoryAttributes) || {};

	// Add all available attributes from the category
	if (item.category?.available_attributes) {
		const availableAttributes = item.category
			.available_attributes as InventoryAttributeDefinition[];
		availableAttributes.forEach((attr) => {
			// Use existing value if available, otherwise use default or undefined
			initialAttributes[attr.name] =
				existingAttributes[attr.name] ?? attr.default_value ?? undefined;
		});
	}

	return {
		item,
		history,
		categories: filterOptions.categories,
		containers: filterOptions.containers,
		initialFormData: {
			container_id: item.container.id!,
			category_id: item.category.id!,
			quantity: item.quantity,
			notes: item.notes || "",
			out_for_maintenance: item.out_for_maintenance || false,
			attributes: initialAttributes,
		},
	};
};
