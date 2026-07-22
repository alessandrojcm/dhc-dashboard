import { authorize } from "$lib/server/auth";
import { apiClientOptions } from "$lib/server/api-client";
import { INVENTORY_READ_ROLES } from "$lib/server/roles";
import {
	inventoryDashboardStats,
	inventoryHistoryIndex,
} from "@dhc/api-client";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, cookies }) => {
	await authorize(locals, INVENTORY_READ_ROLES);
	const options = apiClientOptions(cookies);

	const [statsResponse, historyResponse] = await Promise.all([
		inventoryDashboardStats(options),
		inventoryHistoryIndex({
			...options,
			query: { limit: 10 },
		}),
	]);

	if (statsResponse.error) {
		throw new Error(
			statsResponse.error.errors?.detail ?? "Failed to load inventory stats.",
		);
	}

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
		stats: statsResponse.data.data,
		recentActivity,
	};
};
