import type { Actions } from './$types';
import { fail, redirect } from '@sveltejs/kit';

export const actions: Actions = {
	default: async ({ url, locals: { supabase } }) => {
		const { data, error } = await supabase.auth.signInWithOAuth({
			provider: 'discord',
			options: {
				redirectTo: `${url.origin}/auth/callback?next=/dashboard`
			}
		});
		if (!error) {
			redirect(303, data.url);
		}
		return fail(403, {
			message: error.message
		});
	}
};
