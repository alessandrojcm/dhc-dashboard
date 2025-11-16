import { error } from "@sveltejs/kit";
import { executeWithRLS, getKyselyClient, sql } from "$lib/server/kysely";
import type { PageServerLoadEvent } from "./$types";

export const load = async ({
	params,
	locals,
	parent,
	platform,
}: PageServerLoadEvent) => {
	const { canEdit } = await parent();

	const db = getKyselyClient(platform?.env.HYPERDRIVE!);
	const { session } = await locals.safeGetSession();

	if (!session) {
		throw new Error("No session found");
	}

	// Load container with full details
	const containerData = await executeWithRLS(
		db,
		{ claims: session },
		async (trx) => {
			return Promise.all([
				// Get container with parent
				trx
					.selectFrom("containers as c")
					.leftJoin(
						"containers as parent",
						"parent.id",
						"c.parent_container_id",
					)
					.select([
						"c.id",
						"c.name",
						"c.description",
						"c.parent_container_id",
						"c.created_at",
						"c.updated_at",
						"c.created_by",
						sql<{ id: string; name: string } | null>`
						CASE 
							WHEN parent.id IS NOT NULL THEN
								json_build_object('id', parent.id, 'name', parent.name)
							ELSE NULL
						END
					`.as("parent_container"),
					])
					.where("c.id", "=", params.id)
					.executeTakeFirst(),
				// Get child containers
				trx
					.selectFrom("containers")
					.select(["id", "name"])
					.where("parent_container_id", "=", params.id)
					.execute(),
				// Get items with category info
				trx
					.selectFrom("inventory_items as items")
					.leftJoin(
						"equipment_categories as cat",
						"cat.id",
						"items.category_id",
					)
					.select([
						"items.id",
						"items.category_id",
						"items.container_id",
						"items.attributes",
						"items.quantity",
						"items.notes",
						"items.out_for_maintenance",
						"items.created_at",
						"items.updated_at",
						"items.created_by",
						"items.updated_by",
						sql<{ name: string } | null>`
						CASE 
							WHEN cat.name IS NOT NULL THEN
								json_build_object('name', cat.name)
							ELSE NULL
						END
					`.as("category"),
					])
					.where("items.container_id", "=", params.id)
					.execute(),
			]);
		},
	);

	const [containerBase, childContainers, items] = containerData;

	if (!containerBase) {
		throw error(404, "Container not found");
	}

	// Combine the data to match the expected structure
	const container = {
		...containerBase,
		child_containers: childContainers,
		items: items,
	};

	return {
		container,
		canEdit,
	};
};
