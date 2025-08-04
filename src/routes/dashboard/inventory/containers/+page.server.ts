import type { PageServerLoadEvent } from './$types';

export const load = async ({ locals, parent }: PageServerLoadEvent) => {
	const { canEdit } = await parent();

	// Load containers with hierarchy information
	const { data: containers } = await locals.supabase
		.from('containers')
		.select(
			`
			*,
			parent_container:parent_container_id(id, name),
			child_containers:containers!parent_container_id(id, name),
			item_count:inventory_items(count)
		`
		)
		.order('name');

	return {
		containers: containers || [],
		canEdit
	};
};
