import { env } from "$env/dynamic/private";
import { registerApiErrorReporter } from "$lib/api-error-reporter";

const DEFAULT_API_BASE_URL = "http://127.0.0.1:4000/api";

registerApiErrorReporter();

export function apiBaseUrl(): string {
	return env.API_BASE_URL ?? DEFAULT_API_BASE_URL;
}

/**
 * Minimal `Cookies` shape the server auth/API modules depend on. SvelteKit's
 * real `Cookies` type satisfies this, and tests substitute a fake. ALE-164:
 * the dashboard authenticates through the Phoenix `_dhc_session` cookie, so
 * server-side API calls forward it explicitly via this interface.
 */
export interface Cookies {
	get(name: string): string | undefined;
}

/**
 * ALE-164: SSR/server-load/remote-function API call options. The dashboard
 * authenticates through the Phoenix `_dhc_session` cookie, forwarded to
 * Phoenix with `credentials: 'include'` (browser) or an explicit `cookie`
 * header (SSR). The generated client uses `ky`, which sends cookies when the
 * request is configured with `credentials: 'include'`; for SSR we forward the
 * cookie explicitly because `ky`'s default fetch does not carry request
 * cookies automatically.
 *
 * The transitional `RequireAuth` plug still accepts a Supabase bearer token
 * (until ALE-163), but the dashboard no longer sends one — the cookie is the
 * only credential.
 */
export function apiClientOptions(cookies: Cookies) {
	const sessionCookie = cookies.get("_dhc_session");
	const headers: Record<string, string> = {};
	if (sessionCookie) {
		headers.cookie = `_dhc_session=${sessionCookie}`;
	}

	return {
		baseUrl: apiBaseUrl(),
		credentials: "include" as const,
		headers,
	};
}
