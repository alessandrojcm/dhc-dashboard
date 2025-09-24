import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { fail, error } from '@sveltejs/kit';
import { UpdateWorkshopSchema } from '$lib/schemas/workshops';
import {
	updateWorkshop,
	canEditWorkshop,
	canEditWorkshopPricing,
	type ClubActivityUpdate
} from '$lib/server/workshops';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { message } from 'sveltekit-superforms';
import dayjs from 'dayjs';
import * as Sentry from '@sentry/sveltekit';
import type { PageServerLoad, Actions } from './$types';
import Dinero from 'dinero.js';
import { getKyselyClient } from '$lib/server/kysely';

export const load: PageServerLoad = async ({ locals, params, platform }) => {
	await authorize(locals, WORKSHOP_ROLES);

	const kysely = getKyselyClient(platform!.env.HYPERDRIVE);

	// Fetch workshop data
	const workshop = await kysely
		.selectFrom('club_activities')
		.selectAll()
		.where('id', '=', params.id)
		.executeTakeFirst();

	if (!workshop) {
		throw error(404, 'Workshop not found');
	}

	// Check if workshop can be edited - allow access to edit page even for non-editable workshops
	// The form will show appropriate warnings and disable fields
	const workshopEditable = await canEditWorkshop(params.id, platform!);

	// Check if pricing can be edited
	const pricingEditable = await canEditWorkshopPricing(params.id, platform!);

	// Transform workshop data to form format
	const formData = {
		title: workshop.title,
		description: workshop.description || '',
		location: workshop.location,
		workshop_date: new Date(workshop.start_date),
		workshop_end_date: new Date(workshop.end_date),
		max_capacity: workshop.max_capacity,
		price_member: workshop.price_member / 100, // Convert from cents to euros
		price_non_member: workshop.price_non_member ? workshop.price_non_member / 100 : undefined,
		is_public: workshop.is_public || false,
		refund_deadline_days: workshop.refund_days || null
	};

	return {
		form: await superValidate(formData, valibot(UpdateWorkshopSchema)),
		workshop,
		workshopEditable,
		priceEditingDisabled: !pricingEditable
	};
};

export const actions: Actions = {
	default: async ({ request, locals, platform, params }) => {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const form = await superValidate(request, valibot(UpdateWorkshopSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const kysely = getKyselyClient(platform!.env.HYPERDRIVE);

			// Fetch current workshop to validate edit permissions
			const currentWorkshop = await kysely
				.selectFrom('club_activities')
				.selectAll()
				.where('id', '=', params.id)
				.executeTakeFirst();

			if (!currentWorkshop) {
				return message(form, { error: 'Workshop not found' }, { status: 404 });
			}

			// Check if workshop can be edited
			const workshopEditable = await canEditWorkshop(params.id, platform!);
			if (!workshopEditable) {
				return message(form, { error: 'Only planned workshops can be edited' }, { status: 400 });
			}

			// Check if pricing changes are allowed
			const pricingEditable = await canEditWorkshopPricing(params.id, platform!);
			if (
				!pricingEditable &&
				(form.data.price_member !== undefined || form.data.price_non_member !== undefined)
			) {
				return message(
					form,
					{ error: 'Cannot change pricing when there are already registered attendees' },
					{ status: 400 }
				);
			}
			// Transform form data to database format
			const updateData: ClubActivityUpdate = {
				...form.data,
				start_date: form.data.workshop_date,
				end_date: form.data.workshop_end_date,
				refund_days: form.data.refund_deadline_days
			};
			// @ts-expect-error deleting the property from the spread
			delete updateData['workshop_date'];
			// @ts-expect-error deleting the property from the spread
			delete updateData['workshop_end_date'];
			// @ts-expect-error deleting the property from the spread
			delete updateData['refund_deadline_days'];
			if (form.data.workshop_end_date !== undefined) {
				const endDate = dayjs(form.data.workshop_end_date);
				updateData.end_date = dayjs(form.data.workshop_date)
					.set('hour', endDate.hour())
					.set('minute', endDate.minute())
					.toISOString();
			}

			// Convert euro prices to cents only if pricing changes are allowed
			if (pricingEditable) {
				if (typeof form.data.price_member === 'number') {
					updateData.price_member = Dinero({
						amount: form.data.price_member * 100,
						currency: 'EUR'
					}).getAmount();
				}

				if (typeof form.data.price_non_member === 'number') {
					updateData.price_non_member =
						form.data.is_public && form.data.price_non_member
							? Dinero({ amount: form.data.price_non_member * 100, currency: 'EUR' }).getAmount()
							: updateData.price_member || currentWorkshop.price_member;
				}
			}

			const workshop = await updateWorkshop(params.id, updateData, session, platform!);

			return message(form, {
				success: `Workshop "${workshop.title}" updated successfully!`
			});
		} catch (error) {
			Sentry.captureException(error);
			console.error('Update workshop error:', error);
			return message(
				form,
				{
					error: 'Failed to update workshop. Please try again.'
				},
				{ status: 500 }
			);
		}
	}
};
