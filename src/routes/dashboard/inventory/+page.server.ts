import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';

export const load = async ({ locals }: { locals: App.Locals }) => {
	await authorize(locals, INVENTORY_ROLES);

	// Get inventory statistics
	const [containersResult, categoriesResult, itemsResult, maintenanceResult] = await Promise.all([
		locals.supabase.from('containers').select('id', { count: 'exact', head: true }),
		locals.supabase.from('equipment_categories').select('id', { count: 'exact', head: true }),
		locals.supabase.from('inventory_items').select('id', { count: 'exact', head: true }),
		locals.supabase.from('inventory_items').select('id', { count: 'exact', head: true }).eq('out_for_maintenance', true)
	]);

	// Get recent activity
	const { data: recentActivity } = await locals.supabase
		.from('inventory_history')
		.select(`
			*,
			item:inventory_items(id, attributes),
			old_container:old_container_id(name),
			new_container:new_container_id(name)
		`)
		.order('created_at', { ascending: false })
		.limit(10);

	return {
		stats: {
			containers: containersResult.count || 0,
			categories: categoriesResult.count || 0,
			items: itemsResult.count || 0,
			maintenance: maintenanceResult.count || 0
		},
		recentActivity: recentActivity || []
	};
};
