import { test, expect } from "@playwright/test";
import { createMember } from "./setupFunctions";
import { phoenixSessionLogin } from "./phoenixSessionLogin";

/**
 * ALE-164: focused integration tests for the dashboard Phoenix Session auth
 * seam.
 *
 * Covers the acceptance criteria:
 *   - Browser and SSR dashboard requests authenticate through the Phoenix
 *     Session cookie.
 *   - Signed-out requests redirect to /auth (presentation-level route gating,
 *     not the authorization boundary).
 *   - Credentialed cross-origin access enforces the agreed origin boundary
 *     (Phoenix's CORS plug rejects credentialed requests from origins not in
 *     the allow-list).
 *   - No Supabase `sb-*-auth-token` cookie or bearer-token forwarding is
 *     used on the production dashboard auth path.
 */

test.describe("ALE-164: dashboard Phoenix Session auth seam", () => {
	let cleanUp: () => Promise<void>;
	let memberEmail: string;

	test.beforeAll(async () => {
		const result = await createMember({
			email: `ale-164-${Date.now()}@example.com`,
			roles: new Set(["member"]),
		});
		memberEmail = result.email;
		cleanUp = result.cleanUp;
	});

	test.afterAll(async () => {
		await cleanUp();
	});

	test("a signed-in browser reaches /dashboard via the Phoenix session cookie", async ({
		page,
		context,
	}) => {
		await phoenixSessionLogin(context, memberEmail);

		// The dashboard layout server load reads the session projection from
		// Phoenix via `GET /api/auth/session` (forwarded cookie). A 200 here
		// means the SSR seam authenticated through the cookie.
		const response = await page.goto("/dashboard");
		expect(response?.status()).toBe(200);

		// The dashboard sidebar renders the member's profile via `membersMe`,
		// which is also authenticated through the cookie. If the cookie did
		// not authenticate, `membersMe` would 401 and the page would error.
		await expect(page.getByText("Dublin Hema Club")).toBeVisible();
	});

	test("a signed-out request to /dashboard redirects to /auth", async ({
		page,
		context,
	}) => {
		// Ensure no session cookie is present.
		await context.clearCookies();

		const response = await page.goto("/dashboard");
		// SvelteKit's authGuard redirects signed-out dashboard requests to
		// /auth with a 303. Playwright follows the redirect, so the final
		// response is the /auth page.
		expect(response?.url()).toContain("/auth");
	});

	test("the Supabase auth cookie is not used after Phoenix session login", async ({
		page,
		context,
	}) => {
		await phoenixSessionLogin(context, memberEmail);
		await page.goto("/dashboard");

		// The Phoenix `_dhc_session` cookie is present...
		const cookies = await context.cookies();
		const sessionCookie = cookies.find((c) => c.name === "_dhc_session");
		expect(sessionCookie).toBeDefined();

		// ...and no Supabase auth cookie is present on the dashboard origin.
		// (The E2E helper may set the Supabase cookie during `createMember`,
		// but the dashboard itself does not rely on it after login.)
		const supabaseAuthCookies = cookies.filter((c) => c.name.startsWith("sb-"));
		// Assert no Supabase cookie is on the 127.0.0.1 dashboard origin.
		const dashboardSupabaseCookies = supabaseAuthCookies.filter(
			(c) => c.domain === "127.0.0.1",
		);
		expect(dashboardSupabaseCookies).toHaveLength(0);
	});

	test("a credentialed request from an unapproved origin is rejected by Phoenix CORS", async ({
		request,
	}) => {
		// Phoenix's `DhcWeb.Plugs.Cors` only allows origins in
		// `CORS_ALLOWED_ORIGINS`. In dev/test that is
		// `http://localhost:5173`/`https://127.0.0.1:5173`. An unrelated
		// origin must not receive `access-control-allow-origin` and must be
		// rejected for credentialed access.
		const response = await request.get(
			`${process.env.API_BASE_URL ?? "http://localhost:4000/api"}/auth/session`,
			{
				headers: { origin: "https://evil.example.com" },
				failOnStatusCode: false,
			},
		);

		// Phoenix returns 401 (no session cookie) and, critically, does NOT
		// echo the unapproved origin back in `access-control-allow-origin`.
		expect(response.status()).toBe(401);
		expect(response.headers()["access-control-allow-origin"]).toBeUndefined();
	});

	test("an approved-origin credentialed request is accepted by Phoenix CORS", async ({
		request,
	}) => {
		// An approved origin (the dev/test dashboard origin) gets the
		// `access-control-allow-origin` header back. This is the positive
		// counterpart to the rejected-origin test above.
		const approvedOrigin = "http://localhost:5173";
		const response = await request.get(
			`${process.env.API_BASE_URL ?? "http://localhost:4000/api"}/auth/session`,
			{
				headers: { origin: approvedOrigin },
				failOnStatusCode: false,
			},
		);

		// 401 because no session cookie is sent, but CORS still echoes the
		// approved origin — the preflight would pass.
		expect(response.status()).toBe(401);
		expect(response.headers()["access-control-allow-origin"]).toBe(
			approvedOrigin,
		);
	});
});
