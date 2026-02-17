import { error, fail, isRedirect, redirect } from '@sveltejs/kit';
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import type { AttributeDefinition } from '$lib/schemas/inventory';
import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import { createCategoryService, CategoryUpdateSchema } from '$lib/server/services/inventory';
import type { Action, PageServerLoadEvent } from './$types';

export const load = async ({ params, locals, platform }: PageServerLoadEvent) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const categoryService = createCategoryService(platform!, session);

	// Load category to edit
	const category = await categoryService.findById(params.id);

	if (!category) {
		throw error(404, 'Category not found');
	}

	return {
		form: await superValidate(
			{
				name: category.name,
				description: category.description || undefined,
				available_attributes: (category.available_attributes as AttributeDefinition[]) ?? []
			},
			valibot(CategoryUpdateSchema)
		),
		category
	};
};

export const actions: { [key: string]: Action } = {
	update: async ({ params, request, locals, platform }) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(CategoryUpdateSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const categoryService = createCategoryService(platform!, session);
			await categoryService.update(params.id, form.data);

			redirect(303, `/dashboard/inventory/categories`);
		} catch (error) {
			console.error('Error updating category:', error);
			return fail(500, {
				form,
				error: 'Failed to update category. Please try again.'
			});
		}
	},

	delete: async ({ params, locals, platform }) => {
		const session = await authorize(locals, INVENTORY_ROLES);

		try {
			const categoryService = createCategoryService(platform!, session);
			await categoryService.delete(params.id);

			redirect(303, '/dashboard/inventory/categories');
		} catch (error) {
			if (isRedirect(error)) throw error;
			console.error('Error deleting category:', error);
			return fail(500, {
				error: 'Failed to delete category. Please try again.'
			});
		}
	}
};
