/**
 * Container Service
 *
 * Handles inventory container operations including:
 * - CRUD operations (create, read, update, delete)
 * - Hierarchical container management (parent/child relationships)
 * - Container validation (prevent circular references)
 */

import * as v from 'valibot';
import { sql } from 'kysely';
import { containerSchema } from '$lib/schemas/inventory';
import type { Logger, Kysely, Transaction, KyselyDatabase, Session } from '../shared';
import { executeWithRLS } from '../shared';
import type { InventoryContainer } from './types';

// Export validation schemas for reuse in forms
export const ContainerCreateSchema = containerSchema;
export const ContainerUpdateSchema = containerSchema;

export type ContainerCreateInput = v.InferOutput<typeof ContainerCreateSchema>;
export type ContainerUpdateInput = v.InferOutput<typeof ContainerUpdateSchema>;

/**
 * Service for managing inventory containers
 */
export class ContainerService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		logger?: Logger
	) {
		this.logger = logger ?? console;
	}

	/**
	 * Create a new container
	 */
	async create(input: ContainerCreateInput): Promise<InventoryContainer> {
		this.logger.info('Creating container', { name: input.name });

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				return this._create(trx, input);
			});
		} catch (error) {
			this.logger.error('Failed to create container', { error, input });
			throw new Error('Failed to create container', {
				cause: { originalError: error, input }
			});
		}
	}

	/**
	 * Transactional create method
	 */
	async _create(
		trx: Transaction<KyselyDatabase>,
		input: ContainerCreateInput
	): Promise<InventoryContainer> {
		const result = await trx
			.insertInto('containers')
			.values({
				id: crypto.randomUUID(),
				name: input.name,
				description: input.description || null,
				parent_container_id: input.parent_container_id || null,
				created_by: this.session.user.id,
				created_at: new Date().toISOString(),
				updated_at: new Date().toISOString()
			})
			.returningAll()
			.execute();

		if (!result || result.length === 0) {
			throw new Error('Failed to create container');
		}

		return result[0];
	}

	/**
	 * Find a container by ID
	 */
	async findById(id: string): Promise<InventoryContainer> {
		this.logger.info('Finding container by ID', { containerId: id });

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				return this._findById(trx, id);
			});
		} catch (error) {
			this.logger.error('Failed to find container', {
				error,
				containerId: id
			});
			throw new Error('Container not found', {
				cause: { containerId: id, originalError: error }
			});
		}
	}

	/**
	 * Transactional findById method
	 */
	async _findById(trx: Transaction<KyselyDatabase>, id: string): Promise<InventoryContainer> {
		const container = await trx
			.selectFrom('containers')
			.selectAll()
			.where('id', '=', id)
			.executeTakeFirst();

		if (!container) {
			throw new Error('Container not found', {
				cause: { containerId: id, context: 'ContainerService._findById' }
			});
		}

		return container;
	}

	/**
	 * Find all containers
	 */
	async findMany(): Promise<InventoryContainer[]> {
		this.logger.info('Finding all containers');

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				return trx.selectFrom('containers').selectAll().orderBy('name').execute();
			});
		} catch (error) {
			this.logger.error('Failed to find containers', { error });
			throw new Error('Failed to find containers', {
				cause: { originalError: error }
			});
		}
	}

	/**
	 * Update a container
	 */
	async update(id: string, input: ContainerUpdateInput): Promise<InventoryContainer> {
		this.logger.info('Updating container', { containerId: id, updates: input });

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				return this._update(trx, id, input);
			});
		} catch (error) {
			this.logger.error('Failed to update container', {
				error,
				containerId: id,
				input
			});
			throw new Error('Failed to update container', {
				cause: { containerId: id, originalError: error }
			});
		}
	}

	/**
	 * Transactional update method
	 */
	async _update(
		trx: Transaction<KyselyDatabase>,
		id: string,
		input: ContainerUpdateInput
	): Promise<InventoryContainer> {
		await trx
			.updateTable('containers')
			.set({
				name: input.name,
				description: input.description || null,
				parent_container_id: input.parent_container_id || null,
				updated_at: new Date().toISOString()
			})
			.where('id', '=', id)
			.execute();

		return this._findById(trx, id);
	}

	/**
	 * Delete a container (only if it has no items)
	 */
	async delete(id: string): Promise<void> {
		this.logger.info('Deleting container', { containerId: id });

		try {
			await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				// Check if container has items
				const hasItems = await trx
					.selectFrom('inventory_items')
					.select('id')
					.where('container_id', '=', id)
					.executeTakeFirst();

				if (hasItems) {
					throw new Error('Cannot delete a container that contains items', {
						cause: {
							containerId: id,
							context: 'ContainerService.delete'
						}
					});
				}

				await trx.deleteFrom('containers').where('id', '=', id).execute();
			});
		} catch (error) {
			this.logger.error('Failed to delete container', {
				error,
				containerId: id
			});
			throw error; // Re-throw the error (it's already formatted)
		}
	}

	/**
	 * Get available containers for parent selection (excludes the current container and its descendants)
	 */
	async getAvailableParents(excludeId?: string): Promise<InventoryContainer[]> {
		this.logger.info('Getting available parent containers', { excludeId });

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				const allContainers = await trx
					.selectFrom('containers')
					.selectAll()
					.orderBy('name')
					.execute();

				if (!excludeId) {
					return allContainers;
				}

				// Filter out current container and its descendants
				return this._filterDescendants(allContainers, excludeId);
			});
		} catch (error) {
			this.logger.error('Failed to get available parent containers', {
				error,
				excludeId
			});
			throw new Error('Failed to get available parent containers', {
				cause: { excludeId, originalError: error }
			});
		}
	}

	/**
	 * Filter out a container and all its descendants to prevent circular references
	 */
	private _filterDescendants(
		containers: InventoryContainer[],
		excludeId: string
	): InventoryContainer[] {
		const descendants = new Set([excludeId]);
		let changed = true;

		// Iteratively find all descendants
		while (changed) {
			changed = false;
			containers.forEach((c) => {
				if (
					c.parent_container_id &&
					descendants.has(c.parent_container_id) &&
					!descendants.has(c.id)
				) {
					descendants.add(c.id);
					changed = true;
				}
			});
		}

		return containers.filter((c) => !descendants.has(c.id));
	}

	/**
	 * Get container with item count
	 */
	async getWithItemCount(id: string): Promise<InventoryContainer & { itemCount: number }> {
		this.logger.info('Getting container with item count', { containerId: id });

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				const container = await this._findById(trx, id);

				const itemCount = await trx
					.selectFrom('inventory_items')
					.select((eb) => eb.fn.count('id').as('count'))
					.where('container_id', '=', id)
					.executeTakeFirst();

				return {
					...container,
					itemCount: Number(itemCount?.count || 0)
				};
			});
		} catch (error) {
			this.logger.error('Failed to get container with item count', {
				error,
				containerId: id
			});
			throw new Error('Failed to get container with item count', {
				cause: { containerId: id, originalError: error }
			});
		}
	}

	/**
	 * Get container with all relations (parent, child containers, and items)
	 */
	async getWithRelations(id: string) {
		this.logger.info('Getting container with relations', { containerId: id });

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				const containerData = await Promise.all([
					// Get container with parent
					trx
						.selectFrom('containers as c')
						.leftJoin('containers as parent', 'parent.id', 'c.parent_container_id')
						.select([
							'c.id',
							'c.name',
							'c.description',
							'c.parent_container_id',
							'c.created_at',
							'c.updated_at',
							'c.created_by',
							sql<{ id: string; name: string } | null>`
									CASE 
										WHEN parent.id IS NOT NULL THEN
											json_build_object('id', parent.id, 'name', parent.name)
										ELSE NULL
									END
								`.as('parent_container')
						])
						.where('c.id', '=', id)
						.executeTakeFirst(),
					// Get child containers
					trx
						.selectFrom('containers')
						.select(['id', 'name'])
						.where('parent_container_id', '=', id)
						.execute(),
					// Get items with category info
					trx
						.selectFrom('inventory_items as items')
						.leftJoin('equipment_categories as cat', 'cat.id', 'items.category_id')
						.select([
							'items.id',
							'items.category_id',
							'items.container_id',
							'items.attributes',
							'items.quantity',
							'items.notes',
							'items.out_for_maintenance',
							'items.created_at',
							'items.updated_at',
							'items.created_by',
							'items.updated_by',
							sql<{ name: string } | null>`
									CASE 
										WHEN cat.name IS NOT NULL THEN
											json_build_object('name', cat.name)
										ELSE NULL
									END
								`.as('category')
						])
						.where('items.container_id', '=', id)
						.execute()
				]);

				const [containerBase, childContainers, items] = containerData;

				if (!containerBase) {
					return null;
				}

				// Combine the data to match the expected structure
				return {
					...containerBase,
					child_containers: childContainers,
					items: items
				};
			});
		} catch (error) {
			this.logger.error('Failed to get container with relations', {
				error,
				containerId: id
			});
			throw new Error('Failed to get container with relations', {
				cause: { containerId: id, originalError: error }
			});
		}
	}
}
