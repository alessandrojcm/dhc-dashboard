import { error, fail } from '@sveltejs/kit';
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { itemSchema } from '$lib/schemas/inventory';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import type { PageServerLoad, Action } from './$types';
import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';

export const load: PageServerLoad = async ({ params, locals }) => {
	// Load item with full details and history
	const [itemResult, historyResult, categoriesResult, containersResult] = await Promise.all([
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
				old_container:containers!inventory_history_old_container_id_fkey(name),
				new_container:containers!inventory_history_new_container_id_fkey(name)
			`
			)
			.eq('item_id', params.id)
			.order('created_at', { ascending: false })
			.limit(20),
		locals.supabase
			.from('equipment_categories')
			.select('id, name, available_attributes')
			.order('name'),
		locals.supabase.from('containers').select('id, name, parent_container_id').order('name')
	]);

	if (!itemResult.data) {
		throw error(404, 'Item not found');
	}

	// Initialize all category attributes, preserving existing values
	const initialAttributes: Record<string, any> = {};
	const existingAttributes = itemResult.data.attributes || {};

	// Add all available attributes from the category
	if (itemResult.data.category?.available_attributes) {
		itemResult.data.category.available_attributes.forEach((attr: any) => {
			if (attr.name) {
				// Use existing value if available, otherwise use default or undefined
				initialAttributes[attr.name] =
					existingAttributes[attr.name] ?? attr.default_value ?? undefined;
			}
		});
	}

	const form = await superValidate(
		{
			container_id: itemResult.data.container.id,
			category_id: itemResult.data.category.id,
			quantity: itemResult.data.quantity,
			notes: itemResult.data.notes || '',
			out_for_maintenance: itemResult.data.out_for_maintenance || false,
			attributes: initialAttributes
		},
		valibot(itemSchema)
	);

	return {
		item: itemResult.data,
		history: historyResult.data || [],
		categories: categoriesResult.data || [],
		containers: containersResult.data || [],
		form
	};
};

export const actions: { [key: string]: Action } = {
	default: async ({ request, params, locals, platform }) => {
		const form = await superValidate(request, valibot(itemSchema));

		if (!form.valid) {
			return fail(400, { form });
		}
		const session = await authorize(locals, INVENTORY_ROLES);

		try {
			const db = getKyselyClient(platform!.env.HYPERDRIVE);
			// First update the item
			const updateResult = await executeWithRLS(db, { claims: session }, async (db) => {
				return await db
					.updateTable('inventory_items')
					.set({
						container_id: form.data.container_id,
						category_id: form.data.category_id,
						quantity: form.data.quantity,
						notes: form.data.notes,
						out_for_maintenance: form.data.out_for_maintenance,
						attributes: form.data.attributes,
						updated_by: session.user.id
					})
					.where('id', '=', params.id)
					.returningAll()
					.executeTakeFirst();
			});

			if (!updateResult) {
				return fail(404, { form });
			}

			// Then get the item with all relations in a single query
			const updated = await executeWithRLS(db, { claims: session }, async (db) => {
				return await db
					.selectFrom('inventory_items')
					.leftJoin('containers', 'inventory_items.container_id', 'containers.id')
					.leftJoin(
						'equipment_categories',
						'inventory_items.category_id',
						'equipment_categories.id'
					)
					.select([
						'inventory_items.id',
						'inventory_items.container_id',
						'inventory_items.category_id',
						'inventory_items.quantity',
						'inventory_items.notes',
						'inventory_items.out_for_maintenance',
						'inventory_items.attributes',
						'inventory_items.created_at',
						'inventory_items.updated_at',
						'containers.id as container_id_joined',
						'containers.name as container_name',
						'containers.parent_container_id as container_parent_id',
						'equipment_categories.id as category_id_joined',
						'equipment_categories.name as category_name',
						'equipment_categories.available_attributes as category_attributes'
					])
					.where('inventory_items.id', '=', params.id)
					.executeTakeFirst();
			});

			if (!updated) {
				return fail(404, { form });
			}

			// Transform the flat result into the expected nested structure
			const itemData = {
				id: updated.id,
				container_id: updated.container_id,
				category_id: updated.category_id,
				quantity: updated.quantity,
				notes: updated.notes,
				out_for_maintenance: updated.out_for_maintenance,
				attributes: updated.attributes,
				created_at: updated.created_at,
				updated_at: updated.updated_at,
				container: {
					id: updated.container_id_joined,
					name: updated.container_name,
					parent_container_id: updated.container_parent_id
				},
				category: {
					id: updated.category_id_joined,
					name: updated.category_name,
					available_attributes: updated.category_attributes
				}
			};

			return { form, item: itemData };
		} catch (err) {
			console.error('Failed to update item:', err);
			return fail(500, { form });
		}
	}
};
