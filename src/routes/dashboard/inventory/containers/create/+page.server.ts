import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import { containerSchema } from '$lib/schemas/inventory';
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { fail, isRedirect, redirect } from '@sveltejs/kit';
import * as Sentry from '@sentry/sveltekit';
import { executeWithRLS } from '$lib/server/kysely';
import { getKyselyClient } from '$lib/server/kysely';

export const load = async ({ locals }: { locals: App.Locals }) => {
	await authorize(locals, INVENTORY_ROLES);

	// Load existing containers for parent selection
	const { data: containers } = await locals.supabase
		.from('containers')
		.select('id, name, parent_container_id')
		.order('name');

	return {
		form: await superValidate(valibot(containerSchema)),
		containers: containers || []
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
			const db = getKyselyClient(platform!.env.HYPERDRIVE);
			const result = await executeWithRLS(db, { claims: session }, async (trx) => {
				return await trx
					.insertInto('containers')
					.values({
						id: crypto.randomUUID(),
						name: form.data.name,
						description: form.data.description || null,
						parent_container_id: form.data.parent_container_id || null,
						created_by: session.user.id,
						created_at: new Date().toISOString(),
						updated_at: new Date().toISOString()
					})
					.returningAll()
					.execute();
			});

			redirect(303, `/dashboard/inventory/containers/${result[0].id}`);
		} catch (error) {
			if (isRedirect(error)) {
				throw error;
			}
			Sentry.captureException(error);
			console.error('Error creating container:', error);
			return fail(500, {
				form,
				error: 'Failed to create container. Please try again.'
			});
		}
	}
};
