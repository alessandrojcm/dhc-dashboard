import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import { containerSchema } from '$lib/schemas/inventory';
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { fail, redirect, error, isRedirect, isActionFailure } from '@sveltejs/kit';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import { setMessage } from 'sveltekit-superforms/client';

export const load = async ({ params, locals }: { params: any; locals: App.Locals }) => {
	await authorize(locals, INVENTORY_ROLES);

	// Load container to edit
	const { data: container } = await locals.supabase
		.from('containers')
		.select('*')
		.eq('id', params.id)
		.single();

	if (!container) {
		throw error(404, 'Container not found');
	}

	// Load all containers for parent selection (excluding current container and its descendants)
	const { data: allContainers } = await locals.supabase
		.from('containers')
		.select('id, name, parent_container_id')
		.order('name');

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
				description: container.description || undefined,
				parent_container_id: container.parent_container_id || undefined
			},
			valibot(containerSchema)
		),
		containers: availableContainers,
		container
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
			const db = getKyselyClient(platform!.env.HYPERDRIVE);
			await executeWithRLS(db, { claims: session }, async (trx) => {
				return await trx
					.updateTable('containers')
					.set({
						name: form.data.name,
						description: form.data.description || null,
						parent_container_id: form.data.parent_container_id || null,
						updated_at: new Date().toISOString()
					})
					.where('id', '=', params.id)
					.execute();
			});

			redirect(303, `/dashboard/inventory/containers/${params.id}`);
		} catch (error) {
			if (isRedirect(error)) throw error;
			console.error('Error updating container:', error);
			return fail(500, {
				form,
				error: 'Failed to update container. Please try again.'
			});
		}
	},

	delete: async ({ params, locals, platform, request }) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(containerSchema));

		try {
			const db = getKyselyClient(platform!.env.HYPERDRIVE);
			return await executeWithRLS(db, { claims: session }, async (trx) => {
				const hasChildren = await trx
					.selectFrom('inventory_items')
					.select('id')
					.where('container_id', '=', params.id)
					.executeTakeFirst();
				if (hasChildren) {
					return setMessage(form, 'Cannot delete a container that contains items.', {
						status: 400
					});
				}
				await trx.deleteFrom('containers').where('id', '=', params.id).execute();
				return redirect(303, '/dashboard/inventory/containers');
			});
		} catch (error) {
			if (isRedirect(error) || isActionFailure(error)) throw error;
			console.error('Error deleting container:', error);
			return fail(500, {
				error: 'Failed to delete container. Please try again.'
			});
		}
	}
};
