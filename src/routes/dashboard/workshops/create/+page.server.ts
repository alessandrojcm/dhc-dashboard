import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { fail } from '@sveltejs/kit';
import { CreateWorkshopSchema } from '$lib/schemas/workshops';
import { createWorkshop } from '$lib/server/workshops';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { message } from 'sveltekit-superforms';
import dayjs from 'dayjs';
import * as Sentry from '@sentry/sveltekit';
import type { PageServerLoad, Actions } from './$types';
import Dinero from 'dinero.js';

export const load: PageServerLoad = async ({ locals }) => {
	await authorize(locals, WORKSHOP_ROLES);

	return {
		form: await superValidate(valibot(CreateWorkshopSchema))
	};
};

export const actions: Actions = {
	default: async ({ request, locals, platform }) => {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const form = await superValidate(request, valibot(CreateWorkshopSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			// Transform form data to database format
			const startDateTime = dayjs(form.data.workshop_date).toISOString();
			const endDateTime = dayjs(form.data.workshop_end_date).toISOString();

			// Convert euro prices to cents
			const memberPriceCents = Dinero({
				amount: form.data.price_member * 100,
				currency: 'EUR'
			}).getAmount();
			const nonMemberPriceCents =
				form.data.is_public && form.data.price_non_member
					? Dinero({ amount: form.data.price_non_member * 100, currency: 'EUR' }).getAmount()
					: memberPriceCents;

			const workshopData = {
				title: form.data.title,
				description: form.data.description,
				location: form.data.location,
				start_date: startDateTime,
				end_date: endDateTime,
				max_capacity: form.data.max_capacity,
				price_member: memberPriceCents,
				price_non_member: nonMemberPriceCents,
				is_public: form.data.is_public || false,
				refund_days: form.data.refund_deadline_days,
				announce_discord: form.data.announce_discord || false,
				announce_email: form.data.announce_email || false
			};

			const workshop = await createWorkshop(workshopData, session, platform!);

			return message(form, {
				success: `Workshop "${workshop.title}" created successfully!`
			});
		} catch (error) {
			Sentry.captureException(error);
			console.error('Create workshop error:', error);
			return message(
				form,
				{
					error: 'Failed to create workshop. Please try again.'
				},
				{ status: 500 }
			);
		}
	}
};
