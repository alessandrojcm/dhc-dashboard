import type { Actions, PageServerLoad } from './$types';
import { message, setError, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import beginnersWaitlist from '$lib/schemas/beginnersWaitlist';
import { fail } from '@sveltejs/kit';
import { createClient } from '@supabase/supabase-js';
import { env } from '$env/dynamic/private';
import { PUBLIC_SUPABASE_URL } from '$env/static/public';
import type { Database } from '$database';

// Creating an admin client to be able to insert to the column
const supabaseAdmin = createClient<Database>(PUBLIC_SUPABASE_URL, env.SERVICE_ROLE_KEY);

export const load: PageServerLoad = async () => {
	return {
		form: await superValidate(valibot(beginnersWaitlist)),
		genders: await supabaseAdmin
			.rpc('get_gender_options')
			.throwOnError()
			.then((res) => res.data as string[])
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
		const { error } = await supabaseAdmin.from('waitlist').insert({
			first_name: formData.firstName,
			last_name: formData.lastName,
			email: formData.email,
			date_of_birth: formData.dateOfBirth.toISOString(),
			phone_number: formData.phoneNumber
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
