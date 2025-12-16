import { handleErrorWithSentry, initCloudflareSentryHandle, sentryHandle } from '@sentry/sveltekit';
import { createServerClient } from '@supabase/ssr';
import { type Handle, redirect } from '@sveltejs/kit';
import { sequence } from '@sveltejs/kit/hooks';
import { dev } from '$app/environment';
import { env } from '$env/dynamic/public';
import { canAccessUrl } from '$lib/server/rbacRoles';
import { getRolesFromSession } from '$lib/server/roles';
import type { Database } from '$database';

const supabase: Handle = async ({ event, resolve }) => {
	/**
	 * Creates a Supabase client specific to this server request.
	 *
	 * The Supabase client gets the Auth token from the request cookies.
	 */
	event.locals.supabase = createServerClient<Database>(
		env.PUBLIC_SUPABASE_URL,
		env.PUBLIC_SUPABASE_ANON_KEY,
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
						event.cookies.set(name, value, {
							...options,
							path: '/'
						});
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
	if (event.route.id?.includes('public')) {
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
	if (
		event.route.id?.includes('public') ||
		event.url.pathname.includes('installHook.js.map') ||
		event.url.pathname.includes('api')
	) {
		return resolve(event);
	}
	const { session } = await event.locals.safeGetSession();
	if (!session?.access_token) {
		return resolve(event);
	}
	if (event.url.pathname === `/dashboard/members/${session.user.id}`) {
		return resolve(event);
	}
	const roles = getRolesFromSession(session);
	if (!canAccessUrl(event.url.pathname, roles)) {
		return redirect(303, `/dashboard/members/${session.user.id}`);
	}

	return resolve(event);
};

export const handle: Handle = sequence(
	initCloudflareSentryHandle({
		enabled: !dev,
		dsn: 'https://410c1b65794005c22ea5e8c794ddac10@o4509135535079424.ingest.de.sentry.io/4509135536783440',
		tracesSampleRate: 1
	}),
	sentryHandle(),
	supabase,
	authGuard,
	roleGuard
);
export const handleError = handleErrorWithSentry();
