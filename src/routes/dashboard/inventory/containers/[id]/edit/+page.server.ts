import {
	error,
	fail,
	isActionFailure,
	isRedirect,
	redirect,
} from "@sveltejs/kit";
import { superValidate } from "sveltekit-superforms";
import { valibot } from "sveltekit-superforms/adapters";
import { setMessage } from "sveltekit-superforms/client";
import { containerSchema } from "$lib/schemas/inventory";
import { authorize } from "$lib/server/auth";
import { executeWithRLS, getKyselyClient } from "$lib/server/kysely";
import { INVENTORY_ROLES } from "$lib/server/roles";

export const load = async ({
	params,
	locals,
	platform,
}: {
	params: any;
	locals: App.Locals;
	platform: App.Platform;
}) => {
	await authorize(locals, INVENTORY_ROLES);

	const db = getKyselyClient(platform.env?.HYPERDRIVE!);
	const { session } = await locals.safeGetSession();

	if (!session) {
		throw new Error("No session found");
	}

	// Load container and all containers in a single transaction
	const [container, allContainers] = await executeWithRLS(
		db,
		{ claims: session },
		async (trx) => {
			return Promise.all([
				// Load container to edit
				trx
					.selectFrom("containers")
					.selectAll()
					.where("id", "=", params.id)
					.executeTakeFirst(),
				// Load all containers for parent selection
				trx
					.selectFrom("containers")
					.select(["id", "name", "parent_container_id"])
					.orderBy("name")
					.execute(),
			]);
		},
	);

	if (!container) {
		throw error(404, "Container not found");
	}

	// Filter out current container and its descendants to prevent circular references
	const filterDescendants = (containers: any[], excludeId: string) => {
		const descendants = new Set([excludeId]);
		let changed = true;

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
	};

	const availableContainers = filterDescendants(allContainers || [], params.id);

	return {
		form: await superValidate(
			{
				name: container.name,
				description: container.description || "",
				parent_container_id: container.parent_container_id || "",
			},
			valibot(containerSchema),
		),
		containers: availableContainers,
		container,
	};
};

export const actions = {
	update: async ({ params, request, locals, platform }) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(containerSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const db = getKyselyClient(platform?.env.HYPERDRIVE);
			await executeWithRLS(db, { claims: session }, async (trx) => {
				return await trx
					.updateTable("containers")
					.set({
						name: form.data.name,
						description: form.data.description || null,
						parent_container_id: form.data.parent_container_id || null,
						updated_at: new Date().toISOString(),
					})
					.where("id", "=", params.id)
					.execute();
			});

			redirect(303, `/dashboard/inventory/containers/${params.id}`);
		} catch (error) {
			if (isRedirect(error)) throw error;
			console.error("Error updating container:", error);
			return fail(500, {
				form,
				error: "Failed to update container. Please try again.",
			});
		}
	},

	delete: async ({ params, locals, platform, request }) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(containerSchema));

		try {
			const db = getKyselyClient(platform?.env.HYPERDRIVE);
			return await executeWithRLS(db, { claims: session }, async (trx) => {
				const hasChildren = await trx
					.selectFrom("inventory_items")
					.select("id")
					.where("container_id", "=", params.id)
					.executeTakeFirst();
				if (hasChildren) {
					return setMessage(
						form,
						"Cannot delete a container that contains items.",
						{
							status: 400,
						},
					);
				}
				await trx
					.deleteFrom("containers")
					.where("id", "=", params.id)
					.execute();
				return redirect(303, "/dashboard/inventory/containers");
			});
		} catch (error) {
			if (isRedirect(error) || isActionFailure(error)) throw error;
			console.error("Error deleting container:", error);
			return fail(500, {
				error: "Failed to delete container. Please try again.",
			});
		}
	},
};
