import { error } from '@sveltejs/kit';
import type { AttributeDefinition } from '$lib/schemas/inventory';
import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import { createCategoryService } from '$lib/server/services/inventory';
import type { PageServerLoadEvent } from './$types';

export const load = async ({ params, locals, platform }: PageServerLoadEvent) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const categoryService = createCategoryService(platform!, session);

	// Load category to edit
	const category = await categoryService.findById(params.id);

	if (!category) {
		throw error(404, 'Category not found');
	}

	return {
		category: {
			id: category.id,
			name: category.name,
			description: category.description || '',
			available_attributes: (category.available_attributes as AttributeDefinition[]) ?? []
		}
	};
};
