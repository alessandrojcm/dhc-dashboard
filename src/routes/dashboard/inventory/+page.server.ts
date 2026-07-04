/* eslint-disable @typescript-eslint/no-non-null-asserted-optional-chain */
import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { executeWithRLS, getKyselyClient, sql } from "$lib/server/kysely";
import { INVENTORY_READ_ROLES, INVENTORY_ROLES } from "$lib/server/roles";
import { inventoryHistoryIndex } from "@dhc/api-client";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, platform }) => {
	const session = await authorize(locals, INVENTORY_READ_ROLES);
	const options = apiClientOptions(session);

	// Stats counts still come from direct Kysely queries (pre-existing; not in
	// ALE-108 scope — the migration is progressively replacing these). The
	// recent activity feed now comes from the Phoenix global history endpoint
	// (ALE-108: GET /inventory/history) instead of a hand-rolled Kysely join.
	const kysely = getKyselyClient(platform!.env.HYPERDRIVE);
	const { session: supabaseSession } = await locals.safeGetSession();

	if (!supabaseSession) {
		throw new Error("No session found");
	}

	const [containersCount, categoriesCount, itemsCount, maintenanceCount] =
		await executeWithRLS(kysely, { claims: supabaseSession }, async (trx) => {
			return Promise.all([
				trx
					.selectFrom("containers")
					.select(sql<number>`count(*)`.as("count"))
					.executeTakeFirstOrThrow(),
				trx
					.selectFrom("equipment_categories")
					.select(sql<number>`count(*)`.as("count"))
					.executeTakeFirstOrThrow(),
				trx
					.selectFrom("inventory_items")
					.select(sql<number>`count(*)`.as("count"))
					.executeTakeFirstOrThrow(),
				trx
					.selectFrom("inventory_items")
					.select(sql<number>`count(*)`.as("count"))
					.where("out_for_maintenance", "=", true)
					.executeTakeFirstOrThrow(),
			]);
		});

	const historyResponse = await inventoryHistoryIndex({
		...options,
		query: { limit: 10 },
	});

	if (historyResponse.error) {
		throw new Error(
			historyResponse.error.errors?.detail ??
				"Failed to load inventory activity.",
		);
	}

	const recentActivity = historyResponse.data.data.history.map((h) => ({
		id: h.id,
		action: h.action,
		changed_by: h.changedBy ?? null,
		created_at: h.createdAt,
		item_id: h.itemId,
		new_container_id: h.newContainerId ?? null,
		notes: h.notes ?? null,
		old_container_id: h.oldContainerId ?? null,
		item: h.item
			? {
					id: h.item.id,
					attributes: h.item.attributes ?? {},
				}
			: null,
		old_container: h.oldContainer,
		new_container: h.newContainer,
	}));

	return {
		stats: {
			containers: Number(containersCount.count) || 0,
			categories: Number(categoriesCount.count) || 0,
			items: Number(itemsCount.count) || 0,
			maintenance: Number(maintenanceCount.count) || 0,
		},
		recentActivity,
	};
};
