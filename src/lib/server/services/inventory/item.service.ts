/**
 * Item Service
 *
 * Handles inventory item operations including:
 * - CRUD operations (create, read, update, delete)
 * - Item movement tracking
 * - Maintenance status management
 * - Search and filtering
 */

import type * as v from 'valibot';
import { itemSchema } from '$lib/schemas/inventory';
import type { Logger, Kysely, Transaction, KyselyDatabase, Session } from '../shared';
import { executeWithRLS } from '../shared';
import type {
	InventoryAttributes,
	InventoryAttributeDefinition,
	InventoryItemWithRelations,
	ItemFilters,
	InventoryContainer,
	InventoryCategory
} from './types';

// Export validation schemas for reuse in forms
export const ItemCreateSchema = itemSchema;
export const ItemUpdateSchema = itemSchema;

export type ItemCreateInput = v.InferOutput<typeof ItemCreateSchema>;
export type ItemUpdateInput = v.InferOutput<typeof ItemUpdateSchema>;

/**
 * Service for managing inventory items
 */
export class ItemService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		logger?: Logger
	) {
		this.logger = logger ?? console;
	}

	/**
	 * Create a new inventory item
	 */
	async create(input: ItemCreateInput): Promise<InventoryItemWithRelations> {
		this.logger.info('Creating inventory item', {
			categoryId: input.category_id,
			containerId: input.container_id
		});

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				return this._create(trx, input);
			});
		} catch (error) {
			this.logger.error('Failed to create inventory item', {
				error,
				input
			});
			throw new Error('Failed to create inventory item', {
				cause: { originalError: error, input }
			});
		}
	}

	/**
	 * Transactional create method (for cross-service coordination)
	 */
	async _create(
		trx: Transaction<KyselyDatabase>,
		input: ItemCreateInput
	): Promise<InventoryItemWithRelations> {
		// Create the item
		const result = await trx
			.insertInto('inventory_items')
			.values({
				container_id: input.container_id,
				category_id: input.category_id,
				attributes: input.attributes || {},
				quantity: input.quantity,
				notes: input.notes || null,
				out_for_maintenance: input.out_for_maintenance || false,
				created_at: new Date().toISOString(),
				updated_at: new Date().toISOString(),
				created_by: this.session.user.id
			})
			.returningAll()
			.execute();

		if (!result || result.length === 0) {
			throw new Error('Failed to create item');
		}

		// Fetch the item with full relations
		return this._findById(trx, result[0].id);
	}

	/**
	 * Find an item by ID with full relations (container, category)
	 */
	async findById(id: string): Promise<InventoryItemWithRelations> {
		this.logger.info('Finding inventory item by ID', { itemId: id });

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				return this._findById(trx, id);
			});
		} catch (error) {
			this.logger.error('Failed to find inventory item', {
				error,
				itemId: id
			});
			throw new Error('Inventory item not found', {
				cause: { itemId: id, originalError: error }
			});
		}
	}

	/**
	 * Transactional findById method
	 */
	async _findById(
		trx: Transaction<KyselyDatabase>,
		id: string
	): Promise<InventoryItemWithRelations> {
		const item = await trx
			.selectFrom('inventory_items')
			.leftJoin('containers', 'inventory_items.container_id', 'containers.id')
			.leftJoin('equipment_categories', 'inventory_items.category_id', 'equipment_categories.id')
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
			.where('inventory_items.id', '=', id)
			.executeTakeFirst();

		if (!item) {
			throw new Error('Inventory item not found', {
				cause: { itemId: id, context: 'ItemService._findById' }
			});
		}

		// Transform to expected structure
		return {
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
				available_attributes:
					(item.category_available_attributes as InventoryAttributeDefinition[]) || [],
				attribute_schema: item.category_attribute_schema,
				description: item.category_description,
				created_at: item.category_created_at,
				updated_at: item.category_updated_at
			}
		};
	}

	/**
	 * Find many items with optional filters
	 */
	async findMany(filters?: ItemFilters): Promise<InventoryItemWithRelations[]> {
		this.logger.info('Finding inventory items', { filters });

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				let query = trx
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
					]);

				// Apply filters
				if (filters?.categoryId) {
					query = query.where('inventory_items.category_id', '=', filters.categoryId);
				}
				if (filters?.containerId) {
					query = query.where('inventory_items.container_id', '=', filters.containerId);
				}
				if (filters?.outForMaintenance !== undefined) {
					query = query.where(
						'inventory_items.out_for_maintenance',
						'=',
						filters.outForMaintenance
					);
				}
				if (filters?.search) {
					// Search in attributes (JSONB) using text operator
					query = query.where((eb) =>
						eb.or([
							eb('inventory_items.notes', 'ilike', `%${filters.search}%`),
							eb('equipment_categories.name', 'ilike', `%${filters.search}%`),
							eb('containers.name', 'ilike', `%${filters.search}%`)
						])
					);
				}

				// Pagination
				const page = filters?.page ?? 1;
				const limit = filters?.limit ?? 50;
				const offset = (page - 1) * limit;

				const items = await query
					.orderBy('inventory_items.created_at', 'desc')
					.limit(limit)
					.offset(offset)
					.execute();

				// Transform to expected structure
				return items.map((item) => ({
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
						available_attributes:
							(item.category_available_attributes as InventoryAttributeDefinition[]) || [],
						attribute_schema: item.category_attribute_schema,
						description: item.category_description,
						created_at: item.category_created_at,
						updated_at: item.category_updated_at
					}
				}));
			});
		} catch (error) {
			this.logger.error('Failed to find inventory items', {
				error,
				filters
			});
			throw new Error('Failed to find inventory items', {
				cause: { originalError: error, filters }
			});
		}
	}

	/**
	 * Update an inventory item
	 */
	async update(id: string, input: ItemUpdateInput): Promise<InventoryItemWithRelations> {
		this.logger.info('Updating inventory item', {
			itemId: id,
			updates: input
		});

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				return this._update(trx, id, input);
			});
		} catch (error) {
			this.logger.error('Failed to update inventory item', {
				error,
				itemId: id,
				input
			});
			throw new Error('Failed to update inventory item', {
				cause: { itemId: id, originalError: error }
			});
		}
	}

	/**
	 * Transactional update method
	 */
	async _update(
		trx: Transaction<KyselyDatabase>,
		id: string,
		input: ItemUpdateInput
	): Promise<InventoryItemWithRelations> {
		await trx
			.updateTable('inventory_items')
			.set({
				container_id: input.container_id,
				category_id: input.category_id,
				quantity: input.quantity,
				notes: input.notes,
				out_for_maintenance: input.out_for_maintenance,
				attributes: input.attributes,
				updated_by: this.session.user.id,
				updated_at: new Date().toISOString()
			})
			.where('id', '=', id)
			.execute();

		return this._findById(trx, id);
	}

	/**
	 * Delete an inventory item
	 */
	async delete(id: string): Promise<void> {
		this.logger.info('Deleting inventory item', { itemId: id });

		try {
			await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				await trx.deleteFrom('inventory_items').where('id', '=', id).execute();
			});
		} catch (error) {
			this.logger.error('Failed to delete inventory item', {
				error,
				itemId: id
			});
			throw new Error('Failed to delete inventory item', {
				cause: { itemId: id, originalError: error }
			});
		}
	}

	/**
	 * Move an item to a different container
	 */
	async moveToContainer(
		itemId: string,
		containerId: string,
		notes?: string
	): Promise<InventoryItemWithRelations> {
		this.logger.info('Moving inventory item to container', {
			itemId,
			containerId
		});

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				// Get current item
				const currentItem = await this._findById(trx, itemId);

				// Update container
				await trx
					.updateTable('inventory_items')
					.set({
						container_id: containerId,
						updated_by: this.session.user.id,
						updated_at: new Date().toISOString()
					})
					.where('id', '=', itemId)
					.execute();

				// Create history record
				await trx
					.insertInto('inventory_history')
					.values({
						item_id: itemId,
						action: 'moved',
						old_container_id: currentItem.container_id,
						new_container_id: containerId,
						notes: notes || null,
						changed_by: this.session.user.id,
						created_at: new Date().toISOString()
					})
					.execute();

				return this._findById(trx, itemId);
			});
		} catch (error) {
			this.logger.error('Failed to move inventory item', {
				error,
				itemId,
				containerId
			});
			throw new Error('Failed to move inventory item', {
				cause: { itemId, containerId, originalError: error }
			});
		}
	}

	/**
	 * Mark item for maintenance
	 */
	async markMaintenance(
		itemId: string,
		outForMaintenance: boolean
	): Promise<InventoryItemWithRelations> {
		this.logger.info('Updating maintenance status', {
			itemId,
			outForMaintenance
		});

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				await trx
					.updateTable('inventory_items')
					.set({
						out_for_maintenance: outForMaintenance,
						updated_by: this.session.user.id,
						updated_at: new Date().toISOString()
					})
					.where('id', '=', itemId)
					.execute();

				return this._findById(trx, itemId);
			});
		} catch (error) {
			this.logger.error('Failed to update maintenance status', {
				error,
				itemId,
				outForMaintenance
			});
			throw new Error('Failed to update maintenance status', {
				cause: { itemId, outForMaintenance, originalError: error }
			});
		}
	}

	/**
	 * Get items by container
	 */
	async getByContainer(containerId: string): Promise<InventoryItemWithRelations[]> {
		return this.findMany({ containerId });
	}

	/**
	 * Get items by category
	 */
	async getByCategory(categoryId: string): Promise<InventoryItemWithRelations[]> {
		return this.findMany({ categoryId });
	}

	/**
	 * Get filter options (categories and containers)
	 */
	async getFilterOptions(): Promise<{
		categories: InventoryCategory[];
		containers: InventoryContainer[];
	}> {
		this.logger.info('Getting filter options');

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				const [categories, containers] = await Promise.all([
					trx.selectFrom('equipment_categories').selectAll().orderBy('name').execute(),
					trx.selectFrom('containers').selectAll().orderBy('name').execute()
				]);

				return {
					categories: (categories || []) as InventoryCategory[],
					containers: containers || []
				};
			});
		} catch (error) {
			this.logger.error('Failed to get filter options', { error });
			throw new Error('Failed to get filter options', {
				cause: { originalError: error }
			});
		}
	}
}
