import { error, fail } from '@sveltejs/kit';
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import {
	createItemService,
	createHistoryService,
	ItemUpdateSchema
} from '$lib/server/services/inventory';
import type { InventoryAttributeDefinition, InventoryAttributes } from '$lib/types';
import type { Action, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, locals, platform }) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const itemService = createItemService(platform!, session);
	const historyService = createHistoryService(platform!, session);

	// Get item with relations
	const item = await itemService.findById(params.id);

	if (!item) {
		throw error(404, 'Item not found');
	}

	// Get history for the item
	const [history, filterOptions] = await Promise.all([
		historyService.getByItem(params.id, 20),
		itemService.getFilterOptions()
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

	const form = await superValidate(
		{
			container_id: item.container.id!,
			category_id: item.category.id!,
			quantity: item.quantity,
			notes: item.notes || '',
			out_for_maintenance: item.out_for_maintenance || false,
			attributes: initialAttributes
		},
		valibot(ItemUpdateSchema)
	);

	return {
		item,
		history,
		categories: filterOptions.categories,
		containers: filterOptions.containers,
		form
	};
};

export const actions: { [key: string]: Action } = {
	default: async ({ request, params, locals, platform }) => {
		const form = await superValidate(request, valibot(ItemUpdateSchema));

		if (!form.valid) {
			return fail(400, { form });
		}
		const session = await authorize(locals, INVENTORY_ROLES);

		try {
			const itemService = createItemService(platform!, session);
			const item = await itemService.update(params.id, form.data);

			return { form, item };
		} catch (err) {
			console.error('Failed to update item:', err);
			return fail(500, { form });
		}
	}
};
