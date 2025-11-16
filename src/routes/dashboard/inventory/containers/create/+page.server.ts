import * as Sentry from "@sentry/sveltekit";
import { fail, isRedirect, redirect } from "@sveltejs/kit";
import { superValidate } from "sveltekit-superforms";
import { valibot } from "sveltekit-superforms/adapters";
import { containerSchema } from "$lib/schemas/inventory";
import { authorize } from "$lib/server/auth";
import { executeWithRLS, getKyselyClient } from "$lib/server/kysely";
import { INVENTORY_ROLES } from "$lib/server/roles";
import type { InventoryContainer } from "$lib/types";

export const load = async ({
	locals,
	platform,
}: {
	locals: App.Locals;
	platform: App.Platform;
}) => {
	await authorize(locals, INVENTORY_ROLES);

	const db = getKyselyClient(platform.env?.HYPERDRIVE!);
	const { session } = await locals.safeGetSession();

	if (!session) {
		throw new Error("No session found");
	}

	// Load existing containers for parent selection
	const containers: InventoryContainer[] = await executeWithRLS(
		db,
		{ claims: session },
		async (trx) => {
			return trx.selectFrom("containers").selectAll().orderBy("name").execute();
		},
	);

	return {
		form: await superValidate(valibot(containerSchema)),
		containers: containers || [],
	};
};

export const actions = {
	default: async ({ request, locals, platform }) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(containerSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const db = getKyselyClient(platform?.env.HYPERDRIVE);
			const result = await executeWithRLS(
				db,
				{ claims: session },
				async (trx) => {
					return await trx
						.insertInto("containers")
						.values({
							id: crypto.randomUUID(),
							name: form.data.name,
							description: form.data.description || null,
							parent_container_id: form.data.parent_container_id || null,
							created_by: session.user.id,
							created_at: new Date().toISOString(),
							updated_at: new Date().toISOString(),
						})
						.returningAll()
						.execute();
				},
			);

			redirect(303, `/dashboard/inventory/containers/${result[0].id}`);
		} catch (error) {
			if (isRedirect(error)) {
				throw error;
			}
			Sentry.captureException(error);
			console.error("Error creating container:", error);
			return fail(500, {
				form,
				error: "Failed to create container. Please try again.",
			});
		}
	},
};
