import { authRequestMagicLink } from "@dhc/api-client";
import { invalid } from "@sveltejs/kit";
import * as v from "valibot";
import { form } from "$app/server";
import { env } from "$env/dynamic/private";

const DEFAULT_API_BASE_URL = "http://localhost:4000/api";

function apiBaseUrl(): string {
	return env.API_BASE_URL ?? DEFAULT_API_BASE_URL;
}

const magicLinkSchema = v.object({
	email: v.pipe(
		v.string(),
		v.nonEmpty("Email is required"),
		v.email("Please enter a valid email"),
	),
});

/**
 * ALE-164: the magic-link form posts the email to Phoenix
 * `POST /api/auth/magic-link`. The endpoint is non-enumerating and
 * rate-limited; the result is always `{ sent: true }` on success. The
 * Supabase `signInWithOtp` path is removed.
 *
 * The Phoenix API is credentialed (`credentials: 'include'` is configured on
 * the shared client), but this remote function runs server-side, so we call
 * the generated SDK directly with the base URL rather than going through the
 * browser-configured client.
 */
export const magicLinkAuth = form(magicLinkSchema, async (data, issue) => {
	const { error } = await authRequestMagicLink({
		baseUrl: apiBaseUrl(),
		body: { email: data.email },
	});

	if (error) {
		const detail =
			(error as { errors?: { detail?: string } } | undefined)?.errors?.detail ??
			"Could not send magic link";
		return invalid(issue.email(detail));
	}

	return { success: "Check your email for the magic link" };
});
