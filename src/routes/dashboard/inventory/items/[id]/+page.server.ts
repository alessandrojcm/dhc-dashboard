import { error, fail } from '@sveltejs/kit';
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { itemSchema } from '$lib/schemas/inventory';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import type { PageServerLoad, Action } from './$types';
import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import type {
	InventoryAttributeDefinition,
	InventoryAttributes,
	InventoryItemWithRelations
} from '$lib/types';

export const load: PageServerLoad = async ({ params, locals, platform }) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const db = getKyselyClient(platform!.env.HYPERDRIVE);

	// Load item with full details and history in a single transaction
	const [item, historyRecords, categories, containers] = await executeWithRLS(
		db,
		{ claims: session },
		(trx) =>
			Promise.all([
				// Get item with container and category
				trx
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
						'inventory_items.photo_url',
						'inventory_items.created_at',
						'inventory_items.updated_at',
						'inventory_items.created_by',
						'inventory_items.updated_by',
						'containers.id as container_id_joined',
						'containers.name as container_name',
						'containers.parent_container_id as container_parent_id',
						'equipment_categories.id as category_id_joined',
						'equipment_categories.name as category_name',
						'equipment_categories.available_attributes as category_available_attributes',
						'equipment_categories.attribute_schema as category_attribute_schema',
						'equipment_categories.description as category_description',
						'equipment_categories.created_at as category_created_at',
						'equipment_categories.updated_at as category_updated_at'
					])
					.where('inventory_items.id', '=', params.id)
					.executeTakeFirst(),
				// Get history with container names
				trx
					.selectFrom('inventory_history')
					.leftJoin(
						'containers as old_container',
						'inventory_history.old_container_id',
						'old_container.id'
					)
					.leftJoin(
						'containers as new_container',
						'inventory_history.new_container_id',
						'new_container.id'
					)
					.select([
						'inventory_history.id',
						'inventory_history.item_id',
						'inventory_history.action',
						'inventory_history.old_container_id',
						'inventory_history.new_container_id',
						'inventory_history.notes',
						'inventory_history.changed_by',
						'inventory_history.created_at',
						'old_container.name as old_container_name',
						'new_container.name as new_container_name'
					])
					.where('inventory_history.item_id', '=', params.id)
					.orderBy('inventory_history.created_at', 'desc')
					.limit(20)
					.execute(),
				// Get all categories
				trx
					.selectFrom('equipment_categories')
					.select(['id', 'name', 'available_attributes'])
					.orderBy('name')
					.execute(),
				// Get all containers
				trx
					.selectFrom('containers')
					.select(['id', 'name', 'parent_container_id'])
					.orderBy('name')
					.execute()
			])
	);

	if (!item) {
		throw error(404, 'Item not found');
	}

	// Transform the flat item result into the expected nested structure
	const itemData: InventoryItemWithRelations = {
		id: item.id,
		container_id: item.container_id,
		category_id: item.category_id,
		quantity: item.quantity,
		notes: item.notes,
		out_for_maintenance: item.out_for_maintenance,
		attributes: item.attributes as InventoryAttributes,
		photo_url: item.photo_url,
		created_at: item.created_at,
		updated_at: item.updated_at,
		created_by: item.created_by,
		updated_by: item.updated_by,
		container: {
			id: item.container_id_joined,
			name: item.container_name,
			parent_container_id: item.container_parent_id
		},
		category: {
			id: item.category_id_joined,
			name: item.category_name,
			available_attributes: item.category_available_attributes as InventoryAttributeDefinition[],
			attribute_schema: item.category_attribute_schema,
			description: item.category_description,
			created_at: item.category_created_at,
			updated_at: item.category_updated_at
		}
	};

	// Transform history records to include nested container objects
	const historyData = historyRecords.map((record) => ({
		id: record.id,
		item_id: record.item_id,
		action: record.action,
		old_container_id: record.old_container_id,
		new_container_id: record.new_container_id,
		notes: record.notes,
		changed_by: record.changed_by,
		created_at: record.created_at,
		old_container: record.old_container_name ? { name: record.old_container_name } : null,
		new_container: record.new_container_name ? { name: record.new_container_name } : null
	}));

	// Initialize all category attributes, preserving existing values
	const initialAttributes: InventoryAttributes = {};
	const existingAttributes = (itemData.attributes as InventoryAttributes) || {};

	// Add all available attributes from the category
	if (itemData.category?.available_attributes) {
		const availableAttributes = itemData.category
			.available_attributes as InventoryAttributeDefinition[];
		availableAttributes.forEach((attr) => {
			// Use existing value if available, otherwise use default or undefined
			initialAttributes[attr.name] =
				existingAttributes[attr.name] ?? attr.default_value ?? undefined;
		});
	}

	const form = await superValidate(
		{
			container_id: itemData.container.id!,
			category_id: itemData.category.id!,
			quantity: itemData.quantity,
			notes: itemData.notes || '',
			out_for_maintenance: itemData.out_for_maintenance || false,
			attributes: initialAttributes
		},
		valibot(itemSchema)
	);

	return {
		item: itemData,
		history: historyData,
		categories,
		containers,
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
			const updated = await executeWithRLS(db, { claims: session }, async (db) => {
				await db
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
					.execute();

				return db
					.selectFrom('inventory_items')
					.leftJoin('containers', 'inventory_items.container_id', 'containers.id')
					.leftJoin(
						'equipment_categories',
						'inventory_items.category_id',
						'equipment_categories.id'
					)
					.selectAll('inventory_items')
					.select([
						'containers.id as container_id_joined',
						'containers.name as container_name',
						'containers.parent_container_id as container_parent_id',
						'equipment_categories.description as category_description',
						'equipment_categories.created_at as category_created_at',
						'equipment_categories.updated_at as category_updated_at',
						'equipment_categories.id as category_id_joined',
						'equipment_categories.name as category_name',
						'equipment_categories.available_attributes as category_attributes',
						'equipment_categories.attribute_schema as category_attribute_schema'
					])
					.where('inventory_items.id', '=', params.id)
					.executeTakeFirst();
			});

			if (!updated) {
				return fail(404, { form });
			}

			if (!updated) {
				return fail(404, { form });
			}

			// Transform the flat result into the expected nested structure
			const itemData: InventoryItemWithRelations = {
				// Base inventory_items fields
				id: updated.id,
				container_id: updated.container_id,
				category_id: updated.category_id,
				quantity: updated.quantity,
				notes: updated.notes,
				out_for_maintenance: updated.out_for_maintenance,
				attributes: updated.attributes as InventoryAttributes,
				photo_url: updated.photo_url,
				created_at: updated.created_at,
				updated_at: updated.updated_at,
				created_by: updated.created_by,
				updated_by: updated.updated_by,
				// Nested relations
				container: {
					id: updated.container_id_joined,
					name: updated.container_name,
					parent_container_id: updated.container_parent_id
				},
				category: {
					id: updated.category_id_joined,
					name: updated.category_name,
					available_attributes: updated.category_attributes as InventoryAttributeDefinition[],
					description: updated.category_description,
					created_at: updated.category_created_at,
					updated_at: updated.category_updated_at,
					attribute_schema: updated.category_attribute_schema
				}
			};

			return { form, item: itemData };
		} catch (err) {
			console.error('Failed to update item:', err);
			return fail(500, { form });
		}
	}
};
