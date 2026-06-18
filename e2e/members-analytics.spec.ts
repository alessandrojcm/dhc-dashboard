import { expect, test } from "@playwright/test";
import { createMember } from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

// Verifies the Members dashboard analytics panel renders through the Phoenix
// API (GET /api/members/analytics) after the PostgREST read migration (#124).
//
// The panel previously issued five browser-side Supabase aggregates over
// `member_management_view`; it now issues a single `getMembersAnalytics`
// remote call backed by the typed `membersAnalytics` client. The `{ weapon,
// value }` distribution shape (renamed from `count`) is asserted at the
// Phoenix contract level in `members_controller_test.exs`; this spec guards
// the end-to-end render path.
//
// Requires the Phoenix dev server (`mise run phx-server`) at the configured
// API_BASE_URL alongside the SvelteKit dev server.
test.describe("Members analytics panel", () => {
	let adminMember: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 8);
		adminMember = await createMember({
			email: `members-analytics-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["admin"]),
		});
	});

	test.afterAll(async () => {
		await adminMember?.cleanUp();
	});

	test.beforeEach(async ({ context, page }) => {
		await page.setViewportSize({ width: 1280, height: 720 });
		await loginAsUser(context, adminMember.email);
	});

	test("renders analytics cards and charts via the Phoenix read", async ({
		page,
	}) => {
		// `/dashboard/members` defaults to the Dashboard tab, which mounts the
		// analytics panel. Navigating here exercises the full
		// SvelteKit -> Phoenix `membersAnalytics` path.
		await page.goto("/dashboard/members");

		// The "Total Members" and "Average age" cards render from the Phoenix
		// response's `totalCount` / `averageAge`. Visibility proves the read
		// returned a data envelope rather than degrading.
		await expect(
			page.getByText("Total Members", { exact: true }),
		).toBeVisible();
		await expect(page.getByText("Average age", { exact: true })).toBeVisible();

		// The Gender and Weapon chart panes render from the `genderDistribution`
		// and `weaponDistribution` arrays. The weapon distribution now uses the
		// `{ weapon, value }` shape (renamed from `count`); the chart renders
		// from `value`, so a visible "Preferred Weapons" pane confirms the new
		// shape flows through end-to-end.
		await expect(
			page.getByRole("heading", { name: "Gender Demographics" }),
		).toBeVisible();
		await expect(
			page.getByRole("heading", { name: "Preferred Weapons" }),
		).toBeVisible();
	});
});
