import { createServerClient } from '@supabase/ssr';
import { type Handle, redirect } from '@sveltejs/kit';
import { sequence } from '@sveltejs/kit/hooks';

import { PUBLIC_SUPABASE_ANON_KEY, PUBLIC_SUPABASE_URL } from '$env/static/public';
import type { Database } from './database.types';
import { jwtDecode } from 'jwt-decode';

const supabase: Handle = async ({ event, resolve }) => {
	/**
	 * Creates a Supabase client specific to this server request.
	 *
	 * The Supabase client gets the Auth token from the request cookies.
	 */
	event.locals.supabase = createServerClient<Database>(
		PUBLIC_SUPABASE_URL,
		PUBLIC_SUPABASE_ANON_KEY,
		{
			cookies: {
				getAll: () => event.cookies.getAll(),
				/**
				 * SvelteKit's cookies API requires `path` to be explicitly set in
				 * the cookie options. Setting `path` to `/` replicates previous/
				 * standard behavior.
				 */
				setAll: (cookiesToSet) => {
					cookiesToSet.forEach(({ name, value, options }) => {
						event.cookies.set(name, value, { ...options, path: '/' });
					});
				}
			}
		}
	);

	/**
	 * Unlike `supabase.auth.getSession()`, which returns the session _without_
	 * validating the JWT, this function also calls `getUser()` to validate the
	 * JWT before returning the session.
	 */
	event.locals.safeGetSession = async () => {
		const {
			data: { session }
		} = await event.locals.supabase.auth.getSession();
		if (!session) {
			return { session: null, user: null };
		}

		const {
			data: { user },
			error
		} = await event.locals.supabase.auth.getUser();
		if (error) {
			// JWT validation has failed
			return { session: null, user: null };
		}

		return { session, user };
	};

	return resolve(event, {
		filterSerializedResponseHeaders(name) {
			/**
			 * Supabase libraries use the `content-range` and `x-supabase-api-version`
			 * headers, so we need to tell SvelteKit to pass it through.
			 */
			return name === 'content-range' || name === 'x-supabase-api-version';
		}
	});
};

const authGuard: Handle = async ({ event, resolve }) => {
	if (event.url.pathname.startsWith('/public')) {
		return resolve(event);
	}
	const { session, user } = await event.locals.safeGetSession();
	event.locals.session = session;
	event.locals.user = user;
	if (event.locals.session && event.url.pathname === '/') {
		redirect(303, '/dashboard');
	}

	if (!event.locals.session && event.url.pathname === '/') {
		redirect(303, '/auth');
	}

	if (!event.locals.session && event.url.pathname.startsWith('/dashboard')) {
		redirect(303, '/auth');
	}

	if (event.locals.session && event.url.pathname === '/auth') {
		redirect(303, '/dashboard');
	}

	return resolve(event);
};

const roleGuard: Handle = async ({ event, resolve }) => {
	if (event.url.pathname.startsWith('/public')) {
		return resolve(event);
	}
	const { session } = await event.locals.safeGetSession();
	if (!session?.access_token) {
		return resolve(event);
	}
	const tokenClaim = jwtDecode(session?.access_token!);
	const roles = new Set((tokenClaim as { app_metadata: { roles: string[] } }).app_metadata!.roles);
	if (
		event.url.pathname.includes('beginners-workshop/waitlist') &&
		![
			roles.has('beginners_coordinator'),
			roles.has('president'),
			roles.has('admin'),
			roles.has('coach'),
			roles.has('committee_coordinator')
		].some(Boolean)
	) {
		redirect(303, '/dashboard');
	}

	return resolve(event);
};

export const handle: Handle = sequence(supabase, authGuard, roleGuard);
