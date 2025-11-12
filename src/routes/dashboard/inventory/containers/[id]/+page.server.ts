import type { PageServerLoadEvent } from './$types';
import { error } from '@sveltejs/kit';

export const load = async ({ params, locals, parent }: PageServerLoadEvent) => {
	const { canEdit } = await parent();
	// Load container with full details
	const { data: container } = await locals.supabase
		.from('containers')
		.select(
			`
			*,
			parent_container:parent_container_id(id, name),
			child_containers:containers!parent_container_id(id, name),
			items:inventory_items(
				*,
				category:equipment_categories(name)
			)
		`
		)
		.eq('id', params.id)
		.single();

	if (!container) {
		throw error(404, 'Container not found');
	}

	return {
		container,
		canEdit
	};
};
