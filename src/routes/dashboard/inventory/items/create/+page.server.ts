import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import { itemSchema } from '$lib/schemas/inventory';
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { fail, isRedirect, redirect } from '@sveltejs/kit';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import * as Sentry from '@sentry/sveltekit';

export const load = async ({ url, locals }: { url: URL; locals: App.Locals }) => {
	await authorize(locals, INVENTORY_ROLES);

	// Get pre-selected container or category from URL params
	const preselectedContainer = url.searchParams.get('container');
	const preselectedCategory = url.searchParams.get('category');

	// Load categories and containers
	const [categoriesResult, containersResult] = await Promise.all([
		locals.supabase.from('equipment_categories').select('*').order('name'),
		locals.supabase.from('containers').select('id, name, parent_container_id').order('name')
	]);

	return {
		form: await superValidate(
			{
				container_id: preselectedContainer || '',
				category_id: preselectedCategory || '',
				attributes: {},
				quantity: 1,
				notes: '',
				out_for_maintenance: false
			},
			valibot(itemSchema)
		),
		categories: categoriesResult.data || [],
		containers: containersResult.data || []
	};
};

export const actions = {
	default: async ({
		request,
		locals,
		platform
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
			const result = await executeWithRLS(db, { claims: session }, async (trx) => {
				return await trx
					.insertInto('inventory_items')
					.values({
						container_id: form.data.container_id,
						category_id: form.data.category_id,
						attributes: form.data.attributes,
						quantity: form.data.quantity,
						notes: form.data.notes || null,
						out_for_maintenance: form.data.out_for_maintenance || false,
						created_at: new Date().toISOString(),
						updated_at: new Date().toISOString(),
						created_by: session.user.id
					})
					.returningAll()
					.execute();
			});

			redirect(303, `/dashboard/inventory/items/${result[0].id}`);
		} catch (error) {
			if (isRedirect(error)) {
				throw error;
			}
			Sentry.captureException(error);
			return fail(500, {
				form,
				error: 'Failed to create item. Please try again.'
			});
		}
	}
};
