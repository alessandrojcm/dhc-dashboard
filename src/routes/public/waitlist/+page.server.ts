import type { PageServerLoad } from './$types';
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import beginnersWaitlist from '$lib/schemas/beginnersWaitlist';

export const load: PageServerLoad = async () => {
	return {
		form: await superValidate(valibot(beginnersWaitlist))
	};
};
