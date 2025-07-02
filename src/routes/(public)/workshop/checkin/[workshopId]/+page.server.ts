import type { Actions, PageServerLoad } from './$types';
import { message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { checkinSchema } from '$lib/schemas/workshopCreate';
import { error, fail } from '@sveltejs/kit';
import { getKyselyClient } from '$lib/server/kysely';

export const load: PageServerLoad = async ({ params, platform }) => {
	const { workshopId } = params;
	const db = getKyselyClient(platform?.env.HYPERDRIVE);

	try {
		// Execute both queries in parallel
		const [workshop, attendees] = await Promise.all([
			// Get workshop details
			db
				.selectFrom('workshops')
				.select(['id', 'workshop_date', 'location', 'status'])
				.where('id', '=', workshopId)
				.where('status', '=', 'published')
				.executeTakeFirst(),
			
			// Get confirmed attendees (who can check in) with correct email from waitlist
			db
				.selectFrom('workshop_attendees')
				.innerJoin('user_profiles', 'workshop_attendees.user_profile_id', 'user_profiles.id')
				.innerJoin('waitlist', 'user_profiles.waitlist_id', 'waitlist.id')
				.select([
					'workshop_attendees.status',
					'workshop_attendees.checked_in_at',
					'waitlist.email',
					'user_profiles.first_name',
					'user_profiles.last_name'
				])
				.where('workshop_attendees.workshop_id', '=', workshopId)
				.where('workshop_attendees.status', 'in', ['confirmed', 'pre_checked', 'attended'])
				.execute()
		]);

		if (!workshop) {
			error(404, 'Workshop not found');
		}

		return {
			form: await superValidate(valibot(checkinSchema)),
			workshop: {
				id: workshop.id,
				date: workshop.workshop_date,
				location: workshop.location
			},
			attendees: attendees.map((a) => ({
				email: a.email,
				name: `${a.first_name} ${a.last_name}`,
				status: a.status,
				checkedIn: a.status === 'attended',
				checkedInAt: a.checked_in_at
			}))
		};
	} catch (err) {
		console.error('Error loading workshop check-in data:', err);
		error(500, 'Failed to load workshop data');
	}
};

export const actions: Actions = {
	default: async (event) => {
		const form = await superValidate(event, valibot(checkinSchema));
		if (!form.valid) {
			return fail(422, { form });
		}

		const { workshopId, attendeeEmail } = form.data;
		const db = getKyselyClient(event.platform?.env.HYPERDRIVE);

		try {
			const result = await db.transaction().execute(async (trx) => {
				// Find attendee by email and workshop
				const attendee = await trx
					.selectFrom('workshop_attendees')
					.innerJoin('user_profiles', 'workshop_attendees.user_profile_id', 'user_profiles.id')
					.innerJoin('waitlist', 'user_profiles.waitlist_id', 'waitlist.id')
					.select([
						'workshop_attendees.id',
						'workshop_attendees.status',
						'waitlist.email',
						'user_profiles.first_name',
						'user_profiles.last_name'
					])
					.where('workshop_attendees.workshop_id', '=', workshopId)
					.where('waitlist.email', '=', attendeeEmail)
					.where('workshop_attendees.status', 'in', ['confirmed', 'pre_checked'])
					.executeTakeFirst();

				if (!attendee) {
					throw new Error('Attendee not found or not eligible for check-in');
				}

				const now = new Date().toISOString();

				// Mark as attended
				await trx
					.updateTable('workshop_attendees')
					.set({
						checked_in_at: now,
						status: 'attended'
					})
					.where('id', '=', attendee.id)
					.execute();

				return {
					email: attendee.email,
					first_name: attendee.first_name,
					last_name: attendee.last_name
				};
			});

			return message(form, {
				success: `Successfully checked in ${result.first_name} ${result.last_name}!`,
				attendee: result
			});
		} catch (err) {
			console.error('Check-in error:', err);
			const errorMessage = err instanceof Error ? err.message : 'Failed to check in. Please try again.';
			return message(
				form,
				{ error: errorMessage },
				{ status: 500 }
			);
		}
	}
};
