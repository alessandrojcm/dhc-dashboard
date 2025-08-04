import { error } from '@sveltejs/kit';

export const load = async ({ params, locals }: { params: any; locals: App.Locals }) => {
	// Load item with full details and history
	const [itemResult, historyResult] = await Promise.all([
		locals.supabase
			.from('inventory_items')
			.select(
				`
				*,
				container:containers(id, name, parent_container_id),
				category:equipment_categories(*)
			`
			)
			.eq('id', params.id)
			.single(),
		locals.supabase
			.from('inventory_history')
			.select(
				`
				*,
				old_container:old_container_id(name),
				new_container:new_container_id(name)
			`
			)
			.eq('item_id', params.id)
			.order('created_at', { ascending: false })
			.limit(20)
	]);

	if (!itemResult.data) {
		throw error(404, 'Item not found');
	}

	return {
		item: itemResult.data,
		history: historyResult.data || []
	};
};
