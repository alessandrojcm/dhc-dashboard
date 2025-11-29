import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import { createItemService } from "$lib/server/services/inventory";

export const load = async ({
	locals,
	platform,
}: {
	locals: App.Locals;
	platform: App.Platform;
}) => {
	const session = await authorize(locals, INVENTORY_ROLES);

	// Load filter options only - actual data fetching happens client-side
	const itemService = createItemService(platform!, session);
	const filterOptions = await itemService.getFilterOptions();

	return {
		categories: filterOptions.categories || [],
		containers: filterOptions.containers || [],
	};
};
