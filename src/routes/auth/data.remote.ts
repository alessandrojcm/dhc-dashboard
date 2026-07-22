import { authRequestMagicLink } from "@dhc/api-client";
import { invalid } from "@sveltejs/kit";
import * as v from "valibot";
import { form, getRequestEvent } from "$app/server";
import { apiClientOptions } from "$lib/server/api-client";

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
 * This remote function runs server-side, so the generated SDK receives the
 * centralized server options for the private API base URL and request cookies.
 */
export const magicLinkAuth = form(magicLinkSchema, async (data, issue) => {
	const { cookies } = getRequestEvent();
	const { error } = await authRequestMagicLink({
		...apiClientOptions(cookies),
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
