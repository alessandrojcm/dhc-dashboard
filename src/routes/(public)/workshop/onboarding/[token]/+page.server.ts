import type { Actions, PageServerLoad } from './$types';
import { message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { onboardingSchema } from '$lib/schemas/workshopCreate';
import { error, fail } from '@sveltejs/kit';
import { getKyselyClient } from '$lib/server/kysely';

export const load: PageServerLoad = async ({ params, platform }) => {
  const { token } = params;
  const db = getKyselyClient(platform?.env.HYPERDRIVE);

  // Validate token and get workshop info
  const attendee = await db
    .selectFrom('workshop_attendees')
    .innerJoin('workshops', 'workshop_attendees.workshop_id', 'workshops.id')
    .innerJoin('user_profiles', 'workshop_attendees.user_profile_id', 'user_profiles.id')
    .select([
      'workshops.workshop_date',
      'workshops.location',
      'workshop_attendees.status',
      'workshop_attendees.onboarding_completed_at',
      'user_profiles.first_name',
      'user_profiles.last_name'
    ])
    .where('workshop_attendees.onboarding_token', '=', token)
    .where('workshop_attendees.status', '=', 'confirmed')
    .executeTakeFirst();

  if (!attendee) {
    error(404, 'Invalid token or onboarding not available');
  }

  if (attendee.onboarding_completed_at) {
    error(400, 'Onboarding already completed');
  }

  return {
    form: await superValidate(valibot(onboardingSchema)),
    workshop: {
      date: attendee.workshop_date,
      location: attendee.location
    },
    attendee: {
      first_name: attendee.first_name,
      last_name: attendee.last_name
    }
  };
};

export const actions: Actions = {
  default: async (event) => {
    const form = await superValidate(event, valibot(onboardingSchema));
    if (!form.valid) {
      return fail(422, { form });
    }

    const { token } = event.params;
    const formData = form.data;

    try {
      const response = await fetch(`${event.url.origin}/api/workshop/onboarding`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-onboarding-token': token
        },
        body: JSON.stringify(formData)
      });

      if (!response.ok) {
        const errorData = await response.json();
        throw new Error(errorData.message || 'Failed to complete onboarding');
      }

      return message(form, {
        success: 'Pre-workshop requirements completed successfully! You can now check in on the day of the workshop.'
      });
    } catch (err) {
      console.error(err);
      return message(
        form,
        { error: 'Something went wrong, please try again later.' },
        { status: 500 }
      );
    }
  }
};