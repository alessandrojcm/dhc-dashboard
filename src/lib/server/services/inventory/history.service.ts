/**
 * History Service
 *
 * Handles inventory history tracking including:
 * - Recording item movements
 * - Tracking item changes
 * - Querying historical records
 */

import type { Logger, Kysely, Transaction, KyselyDatabase, Session } from '../shared';
import { executeWithRLS } from '../shared';
import type { InventoryHistoryWithRelations, HistoryAction, InventoryAttributes } from './types';

/**
 * Service for managing inventory history
 */
export class HistoryService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		logger?: Logger
	) {
		this.logger = logger ?? console;
	}

	/**
	 * Get history for a specific item
	 */
	async getByItem(itemId: string, limit = 20): Promise<InventoryHistoryWithRelations[]> {
		this.logger.info('Getting history for item', { itemId, limit });

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				return this._getByItem(trx, itemId, limit);
			});
		} catch (error) {
			this.logger.error('Failed to get item history', {
				error,
				itemId
			});
			throw new Error('Failed to get item history', {
				cause: { itemId, originalError: error }
			});
		}
	}

	/**
	 * Transactional method to get history for an item
	 */
	async _getByItem(
		trx: Transaction<KyselyDatabase>,
		itemId: string,
		limit = 20
	): Promise<InventoryHistoryWithRelations[]> {
		const records = await trx
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
			.leftJoin('inventory_items', 'inventory_history.item_id', 'inventory_items.id')
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
				'new_container.name as new_container_name',
				'inventory_items.id as item_id_joined',
				'inventory_items.attributes as item_attributes'
			])
			.where('inventory_history.item_id', '=', itemId)
			.orderBy('inventory_history.created_at', 'desc')
			.limit(limit)
			.execute();

		// Transform to expected structure
		return records.map((record) => ({
			id: record.id,
			item_id: record.item_id,
			action: record.action as HistoryAction,
			old_container_id: record.old_container_id,
			new_container_id: record.new_container_id,
			notes: record.notes,
			changed_by: record.changed_by,
			created_at: record.created_at,
			item: record.item_id_joined
				? {
						id: record.item_id_joined,
						attributes: (record.item_attributes || {}) as InventoryAttributes
					}
				: null,
			old_container: record.old_container_name ? { name: record.old_container_name } : null,
			new_container: record.new_container_name ? { name: record.new_container_name } : null
		}));
	}

	/**
	 * Record an item movement (used internally by ItemService)
	 */
	async _recordMovement(
		trx: Transaction<KyselyDatabase>,
		itemId: string,
		oldContainerId: string | null,
		newContainerId: string,
		notes?: string,
		changedBy?: string
	): Promise<void> {
		await trx
			.insertInto('inventory_history')
			.values({
				item_id: itemId,
				action: 'moved',
				old_container_id: oldContainerId,
				new_container_id: newContainerId,
				notes: notes || null,
				changed_by: changedBy || this.session.user.id,
				created_at: new Date().toISOString()
			})
			.execute();
	}

	/**
	 * Record item creation
	 */
	async _recordCreation(
		trx: Transaction<KyselyDatabase>,
		itemId: string,
		containerId: string,
		notes?: string
	): Promise<void> {
		await trx
			.insertInto('inventory_history')
			.values({
				item_id: itemId,
				action: 'created',
				old_container_id: null,
				new_container_id: containerId,
				notes: notes || null,
				changed_by: this.session.user.id,
				created_at: new Date().toISOString()
			})
			.execute();
	}

	/**
	 * Record item update
	 */
	async _recordUpdate(
		trx: Transaction<KyselyDatabase>,
		itemId: string,
		notes?: string
	): Promise<void> {
		await trx
			.insertInto('inventory_history')
			.values({
				item_id: itemId,
				action: 'updated',
				old_container_id: null,
				new_container_id: null,
				notes: notes || null,
				changed_by: this.session.user.id,
				created_at: new Date().toISOString()
			})
			.execute();
	}

	/**
	 * Record item deletion - note: items typically aren't deleted, but marked as inactive
	 * This is here for completeness but may not be used
	 */
	async _recordDeletion(
		trx: Transaction<KyselyDatabase>,
		itemId: string,
		notes?: string
	): Promise<void> {
		// Using "updated" action since "deleted" is not in the enum
		await trx
			.insertInto('inventory_history')
			.values({
				item_id: itemId,
				action: 'updated',
				old_container_id: null,
				new_container_id: null,
				notes: notes ? `DELETED: ${notes}` : 'Item deleted',
				changed_by: this.session.user.id,
				created_at: new Date().toISOString()
			})
			.execute();
	}

	/**
	 * Get recent history across all items
	 */
	async getRecent(limit = 50): Promise<InventoryHistoryWithRelations[]> {
		this.logger.info('Getting recent history', { limit });

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				const records = await trx
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
					.leftJoin('inventory_items', 'inventory_history.item_id', 'inventory_items.id')
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
						'new_container.name as new_container_name',
						'inventory_items.id as item_id_joined',
						'inventory_items.attributes as item_attributes'
					])
					.orderBy('inventory_history.created_at', 'desc')
					.limit(limit)
					.execute();

				// Transform to expected structure
				return records.map((record) => ({
					id: record.id,
					item_id: record.item_id,
					action: record.action as HistoryAction,
					old_container_id: record.old_container_id,
					new_container_id: record.new_container_id,
					notes: record.notes,
					changed_by: record.changed_by,
					created_at: record.created_at,
					item: record.item_id_joined
						? {
								id: record.item_id_joined,
								attributes: (record.item_attributes || {}) as InventoryAttributes
							}
						: null,
					old_container: record.old_container_name ? { name: record.old_container_name } : null,
					new_container: record.new_container_name ? { name: record.new_container_name } : null
				}));
			});
		} catch (error) {
			this.logger.error('Failed to get recent history', { error });
			throw new Error('Failed to get recent history', {
				cause: { originalError: error }
			});
		}
	}
}
