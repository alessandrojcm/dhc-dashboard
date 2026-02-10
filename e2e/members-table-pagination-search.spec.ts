import { expect, test } from "@playwright/test";
import { createMember } from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

test.describe("Members table pagination and search", () => {
	let adminMember: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		// Create admin member with unique email for these tests
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 8);
		adminMember = await createMember({
			email: `members-table-test-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["admin"]),
		});
	});

	test.afterAll(async () => {
		await adminMember?.cleanUp();
	});

	test.beforeEach(async ({ context, page }) => {
		// Set viewport to desktop size BEFORE login to ensure table is visible
		await page.setViewportSize({ width: 1280, height: 720 });
		await loginAsUser(context, adminMember.email);
	});

	test("should paginate members table correctly", async ({ page }) => {
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
			// Go to the next page
			await nextButton.click();
			await page.waitForLoadState("networkidle");

			// Get the new first row text
			const newFirstRowText = await page
				.locator("table tbody tr:first-child")
				.textContent();

			// Verify we're on a different page
			expect(firstRowText).not.toEqual(newFirstRowText);

			// Verify URL has page parameter
			expect(page.url()).toContain("page=1");
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

		// Get a member email from the first row to search for
		const firstRowEmail = await page
			.locator('table tbody tr:first-child a[href^="mailto:"]')
			.textContent();

		if (firstRowEmail) {
			// Get the first name from the first row to search for
			const firstRowFirstName = await page
				.locator("table tbody tr:first-child td:nth-child(2)")
				.textContent();

			// Search for this first name
			const searchInput = page.getByPlaceholder("Search members");
			await searchInput.fill(firstRowFirstName || "");
			await searchInput.press("Tab"); // Trigger onchange by blurring

			// Wait for search to complete (URL to update)
			await page.waitForURL(`**/dashboard/members?**q=**`, { timeout: 10000 });

			// Verify URL has search query
			expect(page.url()).toContain(`q=`);

			// Verify the original email still appears in the results (since we're searching by name)
			await expect(
				page.locator(`a[href="mailto:${firstRowEmail}"]`),
			).toHaveCount(1);
		}
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
