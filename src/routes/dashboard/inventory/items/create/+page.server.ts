import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import { createItemService } from '$lib/server/services/inventory';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ url, locals, platform }) => {
	const session = await authorize(locals, INVENTORY_ROLES);

	// Get pre-selected container or category from URL params
	const preselectedContainer = url.searchParams.get('container');
	const preselectedCategory = url.searchParams.get('category');

	// Load filter options using ItemService
	const itemService = createItemService(platform!, session);
	const filterOptions = await itemService.getFilterOptions();

	return {
		initialData: {
			container_id: preselectedContainer || '',
			category_id: preselectedCategory || '',
			attributes: {} as Record<string, unknown>,
			quantity: 1,
			notes: '',
			out_for_maintenance: false
		},
		categories: filterOptions.categories,
		containers: filterOptions.containers
	};
};
