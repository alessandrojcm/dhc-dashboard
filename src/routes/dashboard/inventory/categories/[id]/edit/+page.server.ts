import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import { type AttributeDefinition, categorySchema } from '$lib/schemas/inventory';
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { fail, redirect, error, isRedirect } from '@sveltejs/kit';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import type { Action, PageServerLoadEvent } from './$types';

export const load = async ({ params, locals }: PageServerLoadEvent) => {
	await authorize(locals, INVENTORY_ROLES);

	// Load category to edit
	const { data: category } = await locals.supabase
		.from('equipment_categories')
		.select('*')
		.eq('id', params.id)
		.single();

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
			valibot(categorySchema)
		),
		category
	};
};

export const actions: { [key: string]: Action } = {
	update: async ({ params, request, locals, platform }) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(categorySchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const db = getKyselyClient(platform!.env.HYPERDRIVE);
			await executeWithRLS(db, { claims: session }, async (trx) => {
				return await trx
					.updateTable('equipment_categories')
					.set({
						name: form.data.name,
						description: form.data.description || null,
						available_attributes: form.data.available_attributes,
						updated_at: new Date().toISOString()
					})
					.where('id', '=', params.id)
					.execute();
			});

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
			const db = getKyselyClient(platform!.env.HYPERDRIVE);
			await executeWithRLS(db, { claims: session }, async (trx) => {
				return await trx.deleteFrom('equipment_categories').where('id', '=', params.id).execute();
			});

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
