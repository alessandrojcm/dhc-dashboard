import * as Sentry from '@sentry/sveltekit';
import { fail, isRedirect, redirect } from '@sveltejs/kit';
import { setMessage, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import { createItemService, ItemCreateSchema } from '$lib/server/services/inventory';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({
	url,
	locals,
	platform
}) => {
	const session = await authorize(locals, INVENTORY_ROLES);

	// Get pre-selected container or category from URL params
	const preselectedContainer = url.searchParams.get('container');
	const preselectedCategory = url.searchParams.get('category');

	// Load filter options using ItemService
	const itemService = createItemService(platform!, session);
	const filterOptions = await itemService.getFilterOptions();

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
			valibot(ItemCreateSchema),
			{
				errors: false
			}
		),
		categories: filterOptions.categories,
		containers: filterOptions.containers
	};
};

export const actions: Actions = {
	default: async ({
		request,
		locals,
		platform
	}) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(ItemCreateSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const itemService = createItemService(platform!, session);
			const item = await itemService.create(form.data);

			redirect(303, `/dashboard/inventory/items/${item.id}`);
		} catch (error) {
			if (isRedirect(error)) {
				throw error;
			}
			Sentry.captureException(error);
			console.error('Item creation error:', error);

			// Extract error message from database error if available
			let errorMessage = 'Failed to create item. Please try again.';
			if (error instanceof Error) {
				// Check for JSON schema validation errors
				if (error.message.includes('json_matches_schema')) {
					errorMessage =
						'Item attributes do not match category requirements. Please fill all required fields.';
				} else if (error.message.includes('violates check constraint')) {
					errorMessage =
						'Item attributes validation failed. Please ensure all required fields are filled correctly.';
				}
			}
			setMessage(form, errorMessage);
			return fail(400, {
				form
			});
		}
	}
};
