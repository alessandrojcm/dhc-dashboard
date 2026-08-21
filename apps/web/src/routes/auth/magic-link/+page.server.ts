import { authVerifyMagicLink } from "@dhc/api-client";
import { redirect } from "@sveltejs/kit";
import { apiClientOptions } from "$lib/server/api-client";
import { forwardTrustedResponseCookies } from "$lib/server/trusted-cookie-forwarding";
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
	forwardTrustedResponseCookies(cookies, response.headers);

	redirect(303, "/dashboard?message=Signed%20in");
};
