import { error, fail } from '@sveltejs/kit';
import { message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { createWaitlistService, WaitlistEntrySchema } from '$lib/server/services/members';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async () => {
	const isWaitlistOpen = await supabaseServiceClient
		.from('settings')
		.select('value')
		.eq('key', 'waitlist_open')
		.single()
		.throwOnError()
		.then((result) => result?.data?.value === 'true');
	if (!isWaitlistOpen) {
		error(401, 'The waitlist is currently closed, please come back later.');
	}
	return {
		form: await superValidate(valibot(WaitlistEntrySchema)),
		genders: await supabaseServiceClient
			.rpc('get_gender_options')
			.then((res) => (res.data ?? []) as string[])
	};
};

export const actions: Actions = {
	default: async (event) => {
		const form = await superValidate(event, valibot(WaitlistEntrySchema));
		if (!form.valid) {
			return fail(422, {
				form
			});
		}

		try {
			const waitlistService = createWaitlistService(event.platform!);
			await waitlistService.create(form.data);
		} catch (err) {
			console.error(err);
			return message(
				form,
				{ error: 'Something has gone wrong, please try again later.' },
				{ status: 500 }
			);
		}
		return message(form, {
			success: 'You have been added to the waitlist, we will be in contact soon!'
		});
	}
};
