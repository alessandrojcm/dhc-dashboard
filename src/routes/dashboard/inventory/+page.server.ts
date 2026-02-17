/* eslint-disable @typescript-eslint/no-non-null-asserted-optional-chain */
import { authorize } from '$lib/server/auth';
import { executeWithRLS, getKyselyClient, sql } from '$lib/server/kysely';
import { INVENTORY_ROLES } from '$lib/server/roles';
import type { InventoryAttributes, InventoryHistoryWithRelations } from '$lib/types';

export const load = async ({
	locals,
	platform
}: {
	locals: App.Locals;
	platform: App.Platform;
}) => {
	await authorize(locals, INVENTORY_ROLES);

	const kysely = getKyselyClient(platform.env?.HYPERDRIVE!);
	const { session } = await locals.safeGetSession();

	if (!session) {
		throw new Error('No session found');
	}

	// Get inventory statistics with RLS
	const [containersCount, categoriesCount, itemsCount, maintenanceCount, recentActivity] =
		await executeWithRLS(kysely, { claims: session }, async (trx) => {
			return Promise.all([
				// Count containers
				trx
					.selectFrom('containers')
					.select(sql<number>`count(*)`.as('count'))
					.executeTakeFirstOrThrow(),

				// Count categories
				trx
					.selectFrom('equipment_categories')
					.select(sql<number>`count(*)`.as('count'))
					.executeTakeFirstOrThrow(),

				// Count items
				trx
					.selectFrom('inventory_items')
					.select(sql<number>`count(*)`.as('count'))
					.executeTakeFirstOrThrow(),

				// Count items out for maintenance
				trx
					.selectFrom('inventory_items')
					.select(sql<number>`count(*)`.as('count'))
					.where('out_for_maintenance', '=', true)
					.executeTakeFirstOrThrow(),

				// Get recent activity with relations
				trx
					.selectFrom('inventory_history as ih')
					.leftJoin('inventory_items as item', 'item.id', 'ih.item_id')
					.leftJoin('containers as old_c', 'old_c.id', 'ih.old_container_id')
					.leftJoin('containers as new_c', 'new_c.id', 'ih.new_container_id')
					.select([
						'ih.id',
						'ih.action',
						'ih.changed_by',
						'ih.created_at',
						'ih.item_id',
						'ih.new_container_id',
						'ih.notes',
						'ih.old_container_id',
						sql<{ id: string; attributes: InventoryAttributes } | null>`
							CASE 
								WHEN item.id IS NOT NULL THEN
									json_build_object(
										'id', item.id,
										'attributes', item.attributes
									)
								ELSE NULL
							END
						`.as('item'),
						sql<{ name: string } | null>`
							CASE 
								WHEN old_c.name IS NOT NULL THEN
									json_build_object('name', old_c.name)
								ELSE NULL
							END
						`.as('old_container'),
						sql<{ name: string } | null>`
							CASE 
								WHEN new_c.name IS NOT NULL THEN
									json_build_object('name', new_c.name)
								ELSE NULL
							END
						`.as('new_container')
					])
					.orderBy('ih.created_at', 'desc')
					.limit(10)
					.execute()
			]);
		});

	return {
		stats: {
			containers: Number(containersCount.count) || 0,
			categories: Number(categoriesCount.count) || 0,
			items: Number(itemsCount.count) || 0,
			maintenance: Number(maintenanceCount.count) || 0
		},
		recentActivity: recentActivity as InventoryHistoryWithRelations[]
	};
};
