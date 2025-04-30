import type { Actions, PageServerLoad } from './$types';
import { fail, redirect } from '@sveltejs/kit';
import authSchema from '$lib/schemas/authSchema';
import { message, setError, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';

export const load: PageServerLoad = async () => {
	const form = await superValidate(valibot(authSchema));
	return { form };
};

export const actions: Actions = {
	default: async ({ request, url, locals: { supabase } }) => {
		const form = await superValidate(request, valibot(authSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		const authMethod = form.data.auth_method;

		// Handle Discord authentication
		if (authMethod === 'discord') {
			const { data, error } = await supabase.auth.signInWithOAuth({
				provider: 'discord',
				options: {
					redirectTo: `${url.origin}/auth/callback?next=/dashboard`
				}
			});
			if (!error) {
				redirect(303, data.url);
			}
			
			setError(form, 'auth_method', error.message);
			return fail(403, { form });
		}

		// Handle Magic Link authentication
		if (authMethod === 'magic_link') {
			if (!form.data.email) {
				setError(form, 'email', 'Email is required');
				return fail(400, { form });
			}

			const { error } = await supabase.auth.signInWithOtp({
				email: form.data.email,
				options: {
					emailRedirectTo: `${url.origin}/auth/callback?next=/dashboard`
				}
			});

			if (error) {
				setError(form, 'email', error.message);
				return fail(400, { form });
			}

			return message(form, {
				success: 'Check your email for the magic link'
			});
		}

		// If no auth method is specified, return an error
		setError(form, 'auth_method', 'Invalid authentication method');
		return fail(400, { form });
	}
};
