import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import { categorySchema } from '$lib/schemas/inventory';
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { fail, isRedirect, redirect } from '@sveltejs/kit';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import type { Action, PageServerLoadEvent } from './$types';

export const load = async ({ locals }: PageServerLoadEvent) => {
	await authorize(locals, INVENTORY_ROLES);

	return {
		form: await superValidate({ available_attributes: [] }, valibot(categorySchema))
	};
};

export const actions: { [key: string]: Action } = {
	default: async ({ request, locals, platform }) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(categorySchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const db = getKyselyClient(platform!.env.HYPERDRIVE);
			await executeWithRLS(db, { claims: session }, async (trx) => {
				return await trx
					.insertInto('equipment_categories')
					.values({
						id: crypto.randomUUID(),
						name: form.data.name,
						description: form.data.description || null,
						available_attributes: form.data.available_attributes,
						created_at: new Date().toISOString(),
						updated_at: new Date().toISOString()
					})
					.execute();
			});

			redirect(303, `/dashboard/inventory/categories`);
		} catch (error) {
			if (isRedirect(error)) throw error;
			console.error('Error creating category:', error);
			return fail(500, {
				form,
				error: 'Failed to create category. Please try again.'
			});
		}
	}
};
