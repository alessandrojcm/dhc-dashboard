import * as Sentry from "@sentry/sveltekit";
import { type Handle, type HandleServerError, redirect } from "@sveltejs/kit";
import { sequence } from "@sveltejs/kit/hooks";
import { dev } from "$app/environment";
import { canAccessUrl } from "$lib/server/rbacRoles";
import { getRolesFromSession } from "$lib/server/roles";
import { getPhoenixSession } from "$lib/server/auth";

/**
 * ALE-164: the dashboard authenticates through the Phoenix Session cookie
 * (`_dhc_session`). This hook replaces the Supabase server-client +
 * `auth.getUser()` JWT-validation seam with a credentialed call to Phoenix
 * `GET /api/auth/session`, which returns the Phoenix session projection
 * (`{ principal: { id, email }, roles }`).
 *
 * The browser sends the cookie automatically with `credentials: 'include'`.
 * SvelteKit SSR reads the cookie from the request and forwards it to Phoenix.
 */

const authGuard: Handle = async ({ event, resolve }) => {
	if (event.route.id?.includes("public")) {
		return resolve(event);
	}

	const session = await getPhoenixSession(event.cookies);
	event.locals.session = session;
	event.locals.safeGetSession = async () => ({ session });

	if (event.locals.session && event.url.pathname === "/") {
		redirect(303, "/dashboard");
	}

	if (!event.locals.session && event.url.pathname === "/") {
		redirect(303, "/auth");
	}

	if (!event.locals.session && event.url.pathname.startsWith("/dashboard")) {
		redirect(303, "/auth");
	}

	if (event.locals.session && event.url.pathname === "/auth") {
		redirect(303, "/dashboard");
	}

	return resolve(event);
};

const roleGuard: Handle = async ({ event, resolve }) => {
	if (
		event.route.id?.includes("public") ||
		event.url.pathname.includes("installHook.js.map") ||
		event.url.pathname.includes("api")
	) {
		return resolve(event);
	}
	const { session } = await event.locals.safeGetSession();
	if (!session) {
		return resolve(event);
	}
	if (event.url.pathname === `/dashboard/members/${session.principal.id}`) {
		return resolve(event);
	}
	const roles = getRolesFromSession(session);
	if (!canAccessUrl(event.url.pathname, roles)) {
		return redirect(303, `/dashboard/members/${session.principal.id}`);
	}

	return resolve(event);
};

/**
 * Console-logs every unhandled server error with its full stack before
 * Sentry reports it. SvelteKit only prints unexpected errors itself when
 * `handleError` is NOT overridden — since we override it (for Sentry), and
 * Sentry is disabled in dev, nothing would reach the server console without
 * this. Called for unexpected errors only; errors thrown via `error()` from
 * `@sveltejs/kit` never reach here.
 */
const logUnhandledServerError: HandleServerError = ({
	error,
	event,
	status,
}) => {
	console.error(
		`[server-error] ${status} ${event.request.method} ${event.url.pathname} (route: ${event.route.id ?? "unknown"})`,
		error,
	);
};

export const handle: Handle = sequence(
	Sentry.initCloudflareSentryHandle({
		enabled: !dev,
		dsn: "https://410c1b65794005c22ea5e8c794ddac10@o4509135535079424.ingest.de.sentry.io/4509135536783440",
		tracesSampleRate: 1,
		enableLogs: true,
		enableMetrics: true,
		// Replaces the deprecated `sendDefaultPii: true` with identical
		// behavior: every other dataCollection category already defaults to
		// enabled, so user info is the only one to opt into explicitly.
		dataCollection: { userInfo: true },
	}),
	Sentry.sentryHandle({
		injectFetchProxyScript: true,
	}),
	authGuard,
	roleGuard,
);
export const handleError = Sentry.handleErrorWithSentry(
	logUnhandledServerError,
);
