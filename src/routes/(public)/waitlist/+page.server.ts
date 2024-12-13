import type { Actions, PageServerLoad } from './$types';
import { message, setError, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import beginnersWaitlist from '$lib/schemas/beginnersWaitlist';
import { error, fail } from '@sveltejs/kit';
import type { Database } from '$database';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';


export const load: PageServerLoad = async () => {
	const isWaitlistOpen = await supabaseServiceClient
		.from('settings')
		.select('value')
		.eq('key', 'waitlist_open')
		.single()
		.then(result => result.data.value === 'true')
		.catch(() => false);
	if (!isWaitlistOpen) {
		error(401, 'The waitlist is currently closed, please come back later.');
	}
	return {
		form: await superValidate(valibot(beginnersWaitlist)),
		genders: await supabaseServiceClient
			.rpc('get_gender_options')
			.then((res) => (res.data ?? []) as string[])
	};
};

export const actions: Actions = {
	default: async (event) => {
		const form = await superValidate(event, valibot(beginnersWaitlist));
		if (!form.valid) {
			return fail(422, {
				form
			});
		}
		const formData = form.data;
		const { error } = await supabaseServiceClient.rpc('insert_waitlist_entry', {
			first_name: formData.firstName,
			last_name: formData.lastName,
			email: formData.email,
			date_of_birth: formData.dateOfBirth.toISOString(),
			phone_number: formData.phoneNumber,
			pronouns: formData.pronouns.toLowerCase(),
			gender: formData.gender as Database['public']['Enums']['gender'],
			medical_conditions: formData.medicalConditions
		});
		// Duplicated email
		if (error?.code === '23505') {
			return setError(form, 'email', 'You are already on the waitlist!');
		} else if (error) {
			return fail(500, { error });
		}
		return message(form, {
			text: 'You have been added to the waitlist, we will be in contact soon!'
		});
	}
};
