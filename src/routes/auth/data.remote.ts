import { form, getRequestEvent } from '$app/server';
import { invalid, redirect } from '@sveltejs/kit';
import * as v from 'valibot';

const magicLinkSchema = v.object({
	email: v.pipe(
		v.string(),
		v.nonEmpty('Email is required'),
		v.email('Please enter a valid email')
	)
});

const discordSchema = v.object({});

export const magicLinkAuth = form(magicLinkSchema, async (data, issue) => {
	const event = getRequestEvent();
	const supabase = event.locals.supabase;
	const url = event.url;

	const { error } = await supabase.auth.signInWithOtp({
		email: data.email,
		options: {
			emailRedirectTo: `${url.origin}/auth/callback?next=/dashboard`
		}
	});

	if (error) {
		return invalid(issue.email(error.message));
	}

	return { success: 'Check your email for the magic link' };
});

export const discordAuth = form(discordSchema, async () => {
	const event = getRequestEvent();
	const supabase = event.locals.supabase;
	const url = event.url;

	const { data, error } = await supabase.auth.signInWithOAuth({
		provider: 'discord',
		options: {
			redirectTo: `${url.origin}/auth/callback?next=/dashboard`
		}
	});

	if (error) {
		throw new Error(error.message);
	}

	redirect(303, data.url);
});
