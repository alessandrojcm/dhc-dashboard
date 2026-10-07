import { API_BASE_URL, TRUSTED_FORWARDING_SECRET } from "$app/env/private";
import { getRequestEvent } from "$app/server";
import { registerApiErrorReporter } from "#lib/api-error-reporter.js";

const DEFAULT_API_BASE_URL = "http://127.0.0.1:4000/api";

registerApiErrorReporter();

export function apiBaseUrl(): string {
	return API_BASE_URL ?? DEFAULT_API_BASE_URL;
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
export function apiClientOptions(
	cookies: Cookies,
	forwarding: ClientForwarding = currentRequestForwarding(),
) {
	const sessionCookie = cookies.get("_dhc_session");
	const headers: Record<string, string> = {};
	if (sessionCookie) {
		headers.cookie = `_dhc_session=${sessionCookie}`;
	}
	const forwarded = clientAddressHeaders(forwarding);
	if (forwarded) {
		Object.assign(headers, forwarded);
	}

	return {
		baseUrl: apiBaseUrl(),
		credentials: "include" as const,
		headers,
	};
}

interface ClientAddressHeaders {
	"x-dhc-client-ip": string;
	"x-dhc-forwarding-secret": string;
}

/**
 * Where the browser's address comes from: the shared secret and the current
 * request's client address (`undefined` outside a request).
 */
export interface ClientForwarding {
	secret: string | undefined;
	clientAddress(): string | undefined;
}

function currentRequestForwarding(): ClientForwarding {
	return {
		secret: TRUSTED_FORWARDING_SECRET,
		clientAddress() {
			try {
				return getRequestEvent().getClientAddress();
			} catch {
				// Outside a request (or the adapter cannot tell): there is no
				// client address to forward; Phoenix falls back to its own view.
				return undefined;
			}
		},
	};
}

/**
 * Server-side calls reach Phoenix from this server's egress address, so
 * Phoenix would see every member as one IP (the magic-link rate limit then
 * locks out the whole club). Forward the browser's address in
 * `x-dhc-client-ip`, authenticated by the shared `TRUSTED_FORWARDING_SECRET`
 * that Phoenix's `DhcWeb.Plugs.ClientIp` checks; without the secret Phoenix
 * ignores the header, so nothing is sent when it is unset. This module is
 * server-only, so the secret never reaches the browser.
 */
function clientAddressHeaders(
	forwarding: ClientForwarding,
): ClientAddressHeaders | undefined {
	if (!forwarding.secret) return undefined;

	const clientAddress = forwarding.clientAddress();
	if (!clientAddress) return undefined;

	return {
		"x-dhc-client-ip": clientAddress,
		"x-dhc-forwarding-secret": forwarding.secret,
	};
}
