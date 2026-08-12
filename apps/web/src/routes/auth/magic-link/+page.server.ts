import { authVerifyMagicLink } from "@dhc/api-client";
import { redirect, type Cookies } from "@sveltejs/kit";
import { apiClientOptions } from "$lib/server/api-client";
import type { PageServerLoad } from "./$types";

/**
 * ALE-164: magic-link verify landing route. The magic-link email points the
 * recipient at `/auth/magic-link?token=<token>`. This server load consumes
 * the token by POSTing to Phoenix `/api/auth/magic-link/verify`, which sets
 * the signed `_dhc_session` cookie (Set-Cookie on the Phoenix response) and
 * returns the session projection.
 *
 * Because the Phoenix response sets the cookie via `Set-Cookie`, the generated
 * client response does not automatically propagate it to the browser. We
 * re-set the cookie locally from the raw response retained by Hey API. On
 * success, redirect to `/dashboard`. On failure, redirect back to `/auth`.
 */
export const load: PageServerLoad = async ({ url, cookies }) => {
	const token = url.searchParams.get("token");
	if (!token) {
		throw redirect(303, "/auth#error_description=Invalid%20magic%20link");
	}

	let result: Awaited<ReturnType<typeof authVerifyMagicLink>>;
	try {
		result = await authVerifyMagicLink({
			...apiClientOptions(cookies),
			body: { token },
		});
	} catch {
		redirect(303, "/auth#error_description=Invalid%20or%20expired%20link");
	}

	const { error, response } = result;
	if (error || !response?.ok) {
		const detail =
			response?.status === 403 && error?.errors?.detail
				? error.errors.detail
				: "Invalid or expired link";
		redirect(303, `/auth#error_description=${encodeURIComponent(detail)}`);
	}

	// Phoenix sets the signed `_dhc_session` cookie via Set-Cookie. The
	// cookie attributes (Secure, HttpOnly, SameSite=Lax, Path=/, domain)
	// are chosen by Phoenix. Forward the Set-Cookie to the browser by
	// re-setting it locally with the same value + attributes Phoenix
	// chose. We read the raw Set-Cookie header and parse the cookie
	// name/value out of it.
	const setCookie = response.headers.get("set-cookie");
	if (setCookie) {
		forwardSetCookie(cookies, setCookie);
	}

	redirect(303, "/dashboard?message=Signed%20in");
};

/**
 * Parse a `Set-Cookie` header value and re-set the cookie on the SvelteKit
 * response so the browser receives it. The generated API request does not
 * automatically propagate cross-origin `Set-Cookie`, so we do it explicitly.
 * The cookie name/value and attributes (HttpOnly, SameSite, Path, Max-Age,
 * Domain) come from Phoenix's header.
 */
function forwardSetCookie(cookies: Cookies, setCookieHeader: string): void {
	// Set-Cookie may contain multiple cookies separated by comma, but Phoenix
	// only sets one here. Split on the first `;` to separate the name=value
	// from the attributes.
	const [nameValue, ...attrParts] = setCookieHeader.split(";");
	const eqIndex = nameValue.indexOf("=");
	if (eqIndex === -1) return;
	const name = nameValue.slice(0, eqIndex).trim();
	const value = nameValue.slice(eqIndex + 1).trim();
	if (!name) return;

	const options: {
		path: string;
		httpOnly?: boolean;
		secure?: boolean;
		sameSite?: "lax" | "strict" | "none";
		maxAge?: number;
		domain?: string;
	} = { path: "/" };
	for (const part of attrParts) {
		const trimmed = part.trim();
		const lower = trimmed.toLowerCase();
		if (lower === "httponly") {
			options.httpOnly = true;
		} else if (lower === "secure") {
			options.secure = true;
		} else if (lower.startsWith("samesite=")) {
			options.sameSite = lower.slice("samesite=".length) as
				| "lax"
				| "strict"
				| "none";
		} else if (lower.startsWith("path=")) {
			options.path = lower.slice("path=".length);
		} else if (lower.startsWith("max-age=")) {
			options.maxAge = Number(lower.slice("max-age=".length));
		} else if (lower.startsWith("domain=")) {
			options.domain = lower.slice("domain=".length);
		}
	}

	cookies.set(name, value, options);
}
