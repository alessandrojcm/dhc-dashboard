import { fail, isRedirect, redirect } from "@sveltejs/kit";
import { superValidate } from "sveltekit-superforms";
import { valibot } from "sveltekit-superforms/adapters";
import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import {
	createCategoryService,
	CategoryCreateSchema,
} from "$lib/server/services/inventory";
import type { Action, PageServerLoadEvent } from "./$types";

export const load = async ({ locals }: PageServerLoadEvent) => {
	await authorize(locals, INVENTORY_ROLES);

	return {
		form: await superValidate(
			{ available_attributes: [] },
			valibot(CategoryCreateSchema),
		),
	};
};

export const actions: { [key: string]: Action } = {
	default: async ({ request, locals, platform }) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(CategoryCreateSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const categoryService = createCategoryService(platform!, session);
			await categoryService.create(form.data);

			redirect(303, `/dashboard/inventory/categories`);
		} catch (error) {
			if (isRedirect(error)) throw error;
			console.error("Error creating category:", error);
			return fail(500, {
				form,
				error: "Failed to create category. Please try again.",
			});
		}
	},
};
