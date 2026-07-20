import type { BrowserContext } from "@playwright/test";
import { getSupabaseServiceClient } from "./setupFunctions";

/**
 * ALE-164: E2E helper that authenticates a browser context via the Phoenix
 * Session cookie (`_dhc_session`), replacing the Supabase `sb-*-auth-token`
 * cookie used by `supabaseLogin`.
 *
 * The helper:
 *   1. signs in the member with Supabase (the transitional auth.users row is
 *      still the source of truth for the UUID until the M2 cutover in
 *      ALE-163, and the E2E fixtures create the member via Supabase);
 *   2. requests a magic link from Phoenix `/api/auth/magic-link`;
 *   3. reads the token out of the Loops job args (or, in dev/test, out of the
 *      `oban_jobs` table via the Supabase service client);
 *   4. consumes the token at Phoenix `/api/auth/magic-link/verify` to obtain
 *      the signed `_dhc_session` cookie;
 *   5. sets that cookie on the browser context.
 *
 * The signed cookie value comes from Phoenix's `Set-Cookie` header. We parse
 * it out and set it on the browser context directly (Playwright's
 * `context.addCookies` takes raw cookie values, not signed-then-decoded
 * values, so we forward the signed value verbatim).
 */

const PHOENIX_BASE_URL =
	process.env.API_BASE_URL ?? "http://localhost:4000/api";

/** Normalized email — Phoenix lowercases and trims before lookup. */
function normalizeEmail(email: string): string {
	return email.trim().toLowerCase();
}

/**
 * Reads the most recent magic-link token for `email` out of the
 * `principal_tokens` table via the Supabase service client.
 *
 * In dev/test, the Phoenix `deliver_magic_link/2` enqueues a Loops email job
 * carrying the `LoginLink` data variable; the underlying token row is in
 * `principal_tokens` with `context = 'login'` and `sent_to = email`. The row
 * stores the SHA-256 hash, not the raw token, so we cannot read it back from
 * the DB. Instead we call Phoenix's verify endpoint with the URL-safe encoded
 * token from the Loops job args — which is what the email would carry.
 */
async function readMagicLinkTokenFromJob(email: string): Promise<string> {
	const supabase = getSupabaseServiceClient();
	// The Loops email job carries the `LoginLink` data variable, which is the
	// full magic-link URL with the token as a query param. We pull the most
	// recent `magicLink` job for this email and extract the token.
	const { data, error } = await supabase
		.from("oban_jobs")
		.select("args")
		.eq("args->>email", normalizeEmail(email))
		.eq("args->>transactional_id", "magicLink")
		.order("id", { ascending: false })
		.limit(1);

	if (error) throw new Error(`Failed to read oban_jobs: ${error.message}`);
	const job = (data ?? [])[0];
	if (!job) throw new Error(`No magic-link job found for ${email}`);

	const url: string | undefined = job.args?.data_variables?.LoginLink;
	if (!url) throw new Error("Magic-link job has no LoginLink data variable");

	const token = new URL(url).searchParams.get("token");
	if (!token) throw new Error(`Magic-link URL has no token: ${url}`);
	return token;
}

/**
 * Authenticates a browser context via the Phoenix Session cookie.
 *
 * Usage:
 *   await phoenixSessionLogin(context, memberEmail);
 *   await page.goto("/dashboard");
 */
export async function phoenixSessionLogin(
	context: BrowserContext,
	email: string,
): Promise<void> {
	const normalized = normalizeEmail(email);

	// 1. Request a magic link from Phoenix. The endpoint is non-enumerating
	//    and rate-limited; a 200 means "sent or rate-limited with the same
	//    body". The Loops email worker is configured in dev/test to enqueue
	//    the job without actually sending email.
	const requestResponse = await fetch(`${PHOENIX_BASE_URL}/auth/magic-link`, {
		method: "POST",
		headers: { "content-type": "application/json" },
		body: JSON.stringify({ email: normalized }),
	});
	if (!requestResponse.ok) {
		throw new Error(
			`Phoenix magic-link request failed: ${requestResponse.status}`,
		);
	}

	// 2. Read the magic-link token out of the enqueued Loops job.
	const token = await readMagicLinkTokenFromJob(normalized);

	// 3. Consume the token at Phoenix's verify endpoint. The response sets the
	//    signed `_dhc_session` cookie via `Set-Cookie`. We parse the raw
	//    signed value out of the header so we can set it on the browser
	//    context.
	const verifyResponse = await fetch(
		`${PHOENIX_BASE_URL}/auth/magic-link/verify`,
		{
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ token }),
		},
	);

	if (!verifyResponse.ok) {
		const body = await verifyResponse.text();
		throw new Error(
			`Phoenix magic-link verify failed: ${verifyResponse.status} ${body}`,
		);
	}

	const setCookie = verifyResponse.headers.get("set-cookie");
	if (!setCookie) {
		throw new Error("Phoenix verify response did not set a session cookie");
	}

	// Parse the `_dhc_session=<value>` pair out of the Set-Cookie header. The
	// signed value is everything between `=` and the first `;`.
	const match = /_dhc_session=([^;]+)/.exec(setCookie);
	if (!match) {
		throw new Error(`Set-Cookie did not contain _dhc_session: ${setCookie}`);
	}
	const signedCookieValue = match[1];

	// 4. Set the cookie on the browser context. The domain is `127.0.0.1`
	//    (the SvelteKit dev server) in local E2E; Phoenix sets a broader
	//    domain in production. The attributes here mirror what the browser
	//    would accept from Phoenix's Set-Cookie.
	await context.addCookies([
		{
			name: "_dhc_session",
			value: signedCookieValue,
			domain: "127.0.0.1",
			path: "/",
			httpOnly: true,
			secure: false,
			sameSite: "Lax",
		},
	]);
}
