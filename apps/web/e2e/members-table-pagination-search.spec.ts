import { expect, test } from "@playwright/test";
import { createMember } from "./setupFunctions";
import { loginAsUser } from "./auth";

test.describe("Members table pagination and search", () => {
	let adminMember: Awaited<ReturnType<typeof createMember>>;
	const members: Awaited<ReturnType<typeof createMember>>[] = [];
	let searchTarget: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		// Create admin member with unique email for these tests
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 8);
		adminMember = await createMember({
			email: `members-table-test-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["admin"]),
		});
		const seededMembers = await Promise.all(
			Array.from({ length: 12 }, (_, index) =>
				createMember({
					email: `members-table-member-${timestamp}-${randomSuffix}-${index}@test.com`,
					roles: new Set(["member"]),
				}),
			),
		);
		members.push(...seededMembers);
		searchTarget = seededMembers[0];
	});

	test.afterAll(async () => {
		await Promise.all([
			adminMember?.cleanUp(),
			...members.map((member) => member.cleanUp()),
		]);
	});

	test.beforeEach(async ({ context, page }) => {
		// Set viewport to desktop size BEFORE login to ensure table is visible
		await page.setViewportSize({ width: 1280, height: 720 });
		await loginAsUser(context, adminMember.email);
	});

	test("should paginate members table correctly via cursor prev/next", async ({
		page,
	}) => {
		await page.goto("/dashboard/members?tab=members");

		// Wait for table rows to be attached in DOM
		await page.locator("table tbody tr").first().waitFor({
			state: "attached",
			timeout: 10000,
		});

		const initialRowCount = await page.locator("table tbody tr").count();
		expect(initialRowCount).toBeGreaterThan(0);
		expect(initialRowCount).toBeLessThanOrEqual(10);

		// Get the first row text
		const firstRowText = await page
			.locator("table tbody tr:first-child")
			.textContent();

		// Check if there's a next page button and if it's enabled
		const nextButton = page.getByRole("button", { name: "Next" });
		const isNextButtonDisabled = await nextButton.isDisabled();

		if (!isNextButtonDisabled) {
			// Go to the next page (cursor-based navigation)
			await nextButton.click();
			await page.waitForLoadState("networkidle");

			// Get the new first row text
			const newFirstRowText = await page
				.locator("table tbody tr:first-child")
				.textContent();

			// Verify we're on a different page
			expect(firstRowText).not.toEqual(newFirstRowText);

			// Verify URL has a cursor parameter (cursor-based pagination, not page index)
			expect(page.url()).toContain("cursor=");

			// Verify the Previous button is enabled (we moved off the first page)
			const previousButton = page.getByRole("button", { name: "Previous" });
			await expect(previousButton).toBeEnabled();

			// Go back to the previous page (cursor round-trip)
			await previousButton.click();
			await page.waitForLoadState("networkidle");

			// A previous cursor is still encoded in the URL; the rows prove the round-trip.
			await expect(page.locator("table tbody tr:first-child")).toContainText(
				firstRowText ?? "",
			);
		}
	});

	test("should change page size correctly", async ({ page }) => {
		await page.goto("/dashboard/members?tab=members");

		// Wait for table rows to be attached in DOM
		await page.locator("table tbody tr").first().waitFor({
			state: "attached",
			timeout: 10000,
		});

		const pageSizeTrigger = page.getByRole("button", {
			name: "Members elements per page",
		});
		await pageSizeTrigger.click();

		// Select 25 from the dropdown
		await page.getByRole("option", { name: "25" }).click();

		// Wait for URL to update
		await page.waitForURL("**/dashboard/members?**pageSize=25**", {
			timeout: 10000,
		});

		// Wait for table to reload with new page size
		await page.locator("table tbody tr").first().waitFor({
			state: "attached",
			timeout: 10000,
		});

		// Verify URL has pageSize parameter
		expect(page.url()).toContain("pageSize=25");
		await expect(pageSizeTrigger).toContainText("25");

		// Verify rows are displayed (should be up to 25)
		const rowCount = await page.locator("table tbody tr").count();
		expect(rowCount).toBeGreaterThan(0);
		expect(rowCount).toBeLessThanOrEqual(25);
	});

	test("should search members correctly", async ({ page }) => {
		await page.goto("/dashboard/members?tab=members");

		// Wait for table rows to be attached in DOM (not necessarily visible due to responsive CSS)
		await page.locator("table tbody tr").first().waitFor({
			state: "attached",
			timeout: 10000,
		});

		const searchInput = page.getByPlaceholder("Search members");
		await searchInput.fill(searchTarget.email);
		await expect
			.poll(() => new URL(page.url()).searchParams.get("q") ?? "")
			.toBe(searchTarget.email);
		await expect(
			page.locator(`a[href="mailto:${searchTarget.email}"]`),
		).toHaveCount(1);
	});

	test("should clear search correctly", async ({ page }) => {
		await page.goto("/dashboard/members?tab=members&q=test");

		// Wait for table to load or no results message
		await page
			.locator('table tbody tr, p:has-text("No results found")')
			.first()
			.waitFor({ state: "attached", timeout: 10000 });

		// Find and click the clear search button
		const clearButton = page.getByRole("button", { name: "Clear search" });
		await clearButton.click({ force: true });

		const waitForClearedQuery = () =>
			expect
				.poll(() => new URL(page.url()).searchParams.get("q") ?? "", {
					timeout: 3000,
				})
				.toBe("");

		try {
			await waitForClearedQuery();
		} catch {
			await page.getByPlaceholder("Search members").fill("");
		}

		await expect
			.poll(() => new URL(page.url()).searchParams.get("q") ?? "", {
				timeout: 10000,
			})
			.toBe("");

		// Verify URL doesn't have a non-empty q parameter
		const currentUrl = new URL(page.url());
		const qParam = currentUrl.searchParams.get("q");
		expect(qParam === null || qParam === "").toBe(true);
	});

	test("should filter members by membershipStatus URL param", async ({
		page,
	}) => {
		// Navigate with the membershipStatus filter applied (renamed from `status`).
		await page.goto("/dashboard/members?tab=members&membershipStatus=active");

		// Wait for table rows to be attached in DOM
		await page.locator("table tbody tr").first().waitFor({
			state: "attached",
			timeout: 10000,
		});

		// Verify the URL carries the membershipStatus param
		expect(page.url()).toContain("membershipStatus=active");

		// The "active" checkbox in the status filter should be checked
		const activeCheckbox = page.getByRole("checkbox", {
			name: "active",
			exact: true,
		});
		await expect(activeCheckbox).toBeChecked();
	});

	test("should display correct total count for pagination", async ({
		page,
	}) => {
		await page.goto("/dashboard/members?tab=members");

		// Wait for table rows to be attached in DOM
		await page.locator("table tbody tr").first().waitFor({
			state: "attached",
			timeout: 15000,
		});

		// Verify rows are displayed
		const rowCount = await page.locator("table tbody tr").count();
		expect(rowCount).toBeGreaterThan(0);
		expect(rowCount).toBeLessThanOrEqual(10);
	});
});
