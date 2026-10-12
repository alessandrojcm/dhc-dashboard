import { redirect } from "@sveltejs/kit";
import * as Sentry from "@sentry/sveltekit";
import {
	sequence,
	type Handle,
	type HandleServerError,
} from "@sveltejs/kit/hooks";
import { dev } from "$app/env";
import { guardRoute } from "#lib/server/authorization/index.js";
import { getPhoenixSession } from "#lib/server/auth.js";
import {
	redactIntakeLinks,
	redactPayload,
	redactSentryEvent,
	redactSentrySpan,
} from "#lib/intake-link-redaction.js";

/**
 * ALE-164: the dashboard authenticates through the Phoenix Session cookie
 * (`_dhc_session`). This hook replaces the Supabase server-client +
 * `auth.getUser()` JWT-validation seam with a credentialed call to Phoenix
 * `GET /api/auth/session`, which returns the Phoenix session projection
 * (`{ principal: { id, email }, roles, capabilities }`).
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

/**
 * GH-510: broad route UX gating. Protected-route rules are evaluated by route
 * id through the same capability decisions the sidebar and route loads use
 * (`#lib/server/authorization/index.js`), so navigation, this guard and route-local
 * `require()` calls cannot disagree. Route loads still call `require()` when
 * they need a contextual resource check or a specific response status.
 */
const roleGuard: Handle = async ({ event, resolve }) => {
	// `authGuard` does not populate locals for `(public)` routes; those are
	// ungated here regardless, so treat a missing session as anonymous.
	const outcome = guardRoute(event.locals.session ?? null, {
		id: event.route.id,
		params: event.params,
	});
	if (outcome.kind === "redirect") {
		redirect(303, outcome.location);
	}

	return resolve(event);
};

/**
 * Console-logs every unhandled server error with its full stack before
 * Sentry reports it. SvelteKit only prints unexpected errors itself when
 * `handleError` is NOT overridden — since we override it (for Sentry), and
 * Sentry is disabled in dev, nothing would reach the server console without
 * this. SvelteKit 3 passes every error here, so only `kind: "unknown"` (an
 * unexpected throw, always rendered as a 500) is logged; `error()` app
 * errors, framework 404s and remote-function validation failures are not.
 */
const logUnhandledServerError: HandleServerError = (input) => {
	if (input.kind !== "unknown") return;
	const { error, event } = input;
	console.error(
		`[server-error] 500 ${event.request.method} ${redactIntakeLinks(event.url.pathname)} (route: ${event.route.id ?? "unknown"})`,
		error,
	);
};

export const handle: Handle = sequence(
	Sentry.initCloudflareSentryHandle({
		enabled: !dev,
		dsn: "https://410c1b65794005c22ea5e8c794ddac10@o4509135535079424.ingest.de.sentry.io/4509135536783440",
		tracesSampleRate: 1,
		// Replaces the deprecated `sendDefaultPii: true` with identical
		// behavior: every other dataCollection category already defaults to
		// enabled, so user info is the only one to opt into explicitly.
		dataCollection: { userInfo: true },
		// ALE-381: Intake link tokens never reach Sentry.
		beforeSend: (sentryEvent) => redactSentryEvent(sentryEvent),
		beforeSendSpan: (span) => redactSentrySpan(span),
		beforeBreadcrumb: (breadcrumb) => redactPayload(breadcrumb),
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
