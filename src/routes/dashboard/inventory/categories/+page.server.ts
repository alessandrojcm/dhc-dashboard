import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';

export const load = async ({ locals }: { locals: App.Locals }) => {
	await authorize(locals, INVENTORY_ROLES);

	// Load categories with usage statistics
	const { data: categories } = await locals.supabase
		.from('equipment_categories')
		.select(
			`
			*,
			item_count:inventory_items(count)
		`
		)
		.order('name');

	return {
		categories: categories || []
	};
};
