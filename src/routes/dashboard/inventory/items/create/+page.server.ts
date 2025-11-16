import * as Sentry from "@sentry/sveltekit";
import { fail, isRedirect, redirect } from "@sveltejs/kit";
import { setMessage, superValidate } from "sveltekit-superforms";
import { valibot } from "sveltekit-superforms/adapters";
import { itemSchema } from "$lib/schemas/inventory";
import { authorize } from "$lib/server/auth";
import { executeWithRLS, getKyselyClient } from "$lib/server/kysely";
import { INVENTORY_ROLES } from "$lib/server/roles";

export const load = async ({
	url,
	locals,
	platform,
}: {
	url: URL;
	locals: App.Locals;
	platform: any;
}) => {
	await authorize(locals, INVENTORY_ROLES);

	// Get pre-selected container or category from URL params
	const preselectedContainer = url.searchParams.get("container");
	const preselectedCategory = url.searchParams.get("category");

	const db = getKyselyClient(platform.env.HYPERDRIVE);
	const { session } = await locals.safeGetSession();

	if (!session) {
		throw new Error("No session found");
	}

	// Load categories and containers using Kysely with RLS
	const [categories, containers] = await executeWithRLS(
		db,
		{ claims: session },
		async (trx) => {
			return Promise.all([
				trx
					.selectFrom("equipment_categories")
					.selectAll()
					.orderBy("name")
					.execute(),
				trx
					.selectFrom("containers")
					.select(["id", "name", "parent_container_id"])
					.orderBy("name")
					.execute(),
			]);
		},
	);

	return {
		form: await superValidate(
			{
				container_id: preselectedContainer || "",
				category_id: preselectedCategory || "",
				attributes: {},
				quantity: 1,
				notes: "",
				out_for_maintenance: false,
			},
			valibot(itemSchema),
			{
				errors: false,
			},
		),
		categories,
		containers,
	};
};

export const actions = {
	default: async ({
		request,
		locals,
		platform,
	}: {
		request: Request;
		locals: App.Locals;
		platform: any;
	}) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(itemSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const db = getKyselyClient(platform.env.HYPERDRIVE);
			const result = await executeWithRLS(
				db,
				{ claims: session },
				async (trx) => {
					return await trx
						.insertInto("inventory_items")
						.values({
							container_id: form.data.container_id,
							category_id: form.data.category_id,
							attributes: form.data.attributes,
							quantity: form.data.quantity,
							notes: form.data.notes || null,
							out_for_maintenance: form.data.out_for_maintenance || false,
							created_at: new Date().toISOString(),
							updated_at: new Date().toISOString(),
							created_by: session.user.id,
						})
						.returningAll()
						.execute();
				},
			);

			redirect(303, `/dashboard/inventory/items/${result[0].id}`);
		} catch (error) {
			if (isRedirect(error)) {
				throw error;
			}
			Sentry.captureException(error);
			console.error("Item creation error:", error);

			// Extract error message from database error if available
			let errorMessage = "Failed to create item. Please try again.";
			if (error instanceof Error) {
				// Check for JSON schema validation errors
				if (error.message.includes("json_matches_schema")) {
					errorMessage =
						"Item attributes do not match category requirements. Please fill all required fields.";
				} else if (error.message.includes("violates check constraint")) {
					errorMessage =
						"Item attributes validation failed. Please ensure all required fields are filled correctly.";
				}
			}
			setMessage(form, errorMessage);
			return fail(400, {
				form,
			});
		}
	},
};
