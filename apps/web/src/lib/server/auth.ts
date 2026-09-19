import { authSessionShowSession } from "@dhc/api-client";
import { env } from "$env/dynamic/private";
import { authorizationFor, type Capability } from "./authorization";
import type { Cookies } from "./api-client";

export interface PhoenixSessionClient {
	showSession(options: {
		baseUrl: string;
		headers: Record<string, string>;
	}): Promise<{
		data?: { data: PhoenixSessionProjection };
		error?: unknown;
	}>;
}

const defaultSessionClient: PhoenixSessionClient = {
	showSession: async (options) => authSessionShowSession(options),
};

const DEFAULT_API_BASE_URL = "http://127.0.0.1:4000/api";

/**
 * The Phoenix session projection (`GET /api/auth/session` body). The
 * authoritative login identity plus the current live roles. No `is_active`,
 * no raw token, no Supabase `sub`/bearer/refresh compatibility.
 */
export type PhoenixSessionProjection = {
	principal: { id: string; email: string };
	roles: string[];
};

/**
 * ALE-164: the dashboard authenticates through the Phoenix Session cookie
 * (`_dhc_session`). This module replaces the Supabase server-client +
 * `auth.getUser()` JWT-validation seam with a single credentialed call to
 * Phoenix `GET /api/auth/session`, which returns the Phoenix session
 * projection (`{ principal: { id, email }, roles }`).
 *
 * The browser sends the cookie automatically with `credentials: 'include'`.
 * SvelteKit SSR cannot rely on the browser, so server loads / remote
 * functions forward the cookie explicitly through the `cookie` header to
 * Phoenix (Phoenix's `RequireAuth` and `RequireSession` plugs both accept it).
 */

function apiBaseUrl(): string {
	return env.API_BASE_URL ?? DEFAULT_API_BASE_URL;
}

/**
 * Reads the `_dhc_session` cookie from the request and forwards it to
 * Phoenix `GET /api/auth/session`. Returns the session projection when
 * Phoenix reports a valid, active session, or `null` otherwise (401, network
 * error, missing cookie). Never throws — a failure here is observable as
 * "no session", which the guards turn into a redirect to `/auth`.
 *
 * @param cookies the SvelteKit `Cookies` API for the current request.
 */
export async function getPhoenixSession(
	cookies: Cookies,
	client: PhoenixSessionClient = defaultSessionClient,
): Promise<PhoenixSessionProjection | null> {
	const sessionCookie = cookies.get("_dhc_session");
	if (!sessionCookie) return null;

	try {
		const { data, error } = await client.showSession({
			baseUrl: apiBaseUrl(),
			// Forward the signed cookie verbatim; Phoenix verifies the
			// signature via `Plug.Conn.fetch_cookies(signed: [...])`.
			headers: { cookie: `_dhc_session=${sessionCookie}` },
		});

		if (error || !data) return null;
		return data.data;
	} catch {
		// Network/decode failure: treat as signed-out. The guards redirect to
		// /auth; we never throw here because a broken Phoenix should not
		// crash page rendering.
		return null;
	}
}

// Re-export `Cookies` so existing imports from `$lib/server/auth` keep
// working. The type lives in `./api-client` to avoid a circular import.
export type { Cookies };

/**
 * Authorize a request against a capability. Returns the session projection on
 * success; throws a SvelteKit `error()` with the decision's status otherwise
 * (401 anonymous, 403 forbidden). GH-510: a thin adapter over
 * `authorizationFor(session).require(capability)` for callers that only need
 * the session back.
 */
export async function authorize(
	locals: App.Locals,
	capability: Capability,
): Promise<PhoenixSessionProjection> {
	const { session } = await locals.safeGetSession();
	authorizationFor(session).require(capability);
	// `require` throws for anonymous sessions, so `session` is non-null here.
	return session!;
}
