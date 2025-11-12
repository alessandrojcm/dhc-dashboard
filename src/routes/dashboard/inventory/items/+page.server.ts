import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';

export const load = async ({ url, locals }: { url: URL; locals: App.Locals }) => {
	await authorize(locals, INVENTORY_ROLES);

	// Get filter parameters
	const categoryFilter = url.searchParams.get('category');
	const containerFilter = url.searchParams.get('container');
	const search = url.searchParams.get('search');
	const maintenanceFilter = url.searchParams.get('maintenance');
	const page = parseInt(url.searchParams.get('page') || '1');
	const limit = parseInt(url.searchParams.get('limit') || '20');
	const offset = (page - 1) * limit;

	// Build query
	let query = locals.supabase.from('inventory_items').select(
		`
			*,
			container:containers(id, name),
			category:equipment_categories(id, name)
		`,
		{ count: 'exact' }
	);

	// Apply filters
	if (categoryFilter) {
		query = query.eq('category_id', categoryFilter);
	}
	if (containerFilter) {
		query = query.eq('container_id', containerFilter);
	}
	if (maintenanceFilter === 'true') {
		query = query.eq('out_for_maintenance', true);
	} else if (maintenanceFilter === 'false') {
		query = query.eq('out_for_maintenance', false);
	}
	if (search) {
		// Search in attributes JSONB field using case-insensitive pattern matching
		// This searches across all attribute values in the JSONB object
		query = query.or(
			`attributes->name.ilike.%${search}%,attributes->brand.ilike.%${search}%,attributes->type.ilike.%${search}%,attributes->model.ilike.%${search}%`
		);
	}

	// Apply pagination and ordering
	const { data: items, count } = await query
		.range(offset, offset + limit - 1)
		.order('created_at', { ascending: false });

	// Load categories and containers for filters
	const [categoriesResult, containersResult] = await Promise.all([
		locals.supabase.from('equipment_categories').select('id, name').order('name'),
		locals.supabase.from('containers').select('id, name').order('name')
	]);

	return {
		items: items || [],
		categories: categoriesResult.data || [],
		containers: containersResult.data || [],
		pagination: {
			page,
			limit,
			total: count || 0,
			totalPages: Math.ceil((count || 0) / limit)
		},
		filters: {
			category: categoryFilter,
			container: containerFilter,
			search,
			maintenance: maintenanceFilter
		}
	};
};
