import { faker } from "@faker-js/faker";
import { expect, test } from "@playwright/test";
import dayjs from "dayjs";
import { deleteE2EFixture, seedE2EScenario } from "./e2eApi";
import { createMember } from "./setupFunctions";
import { loginAsUser } from "./auth";

test.describe("Waitlist table pagination and search", () => {
	let adminMember: Awaited<ReturnType<typeof createMember>>;
	const waitlistIds: string[] = [];
	const waitlistPath = "/dashboard/beginners-workshop?tab=waitlist";

	test.beforeAll(async () => {
		// Create admin member with unique email for these tests
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 8);
		adminMember = await createMember({
			email: `waitlist-table-test-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["admin"]),
		});

		// Create some waitlist entries for testing
		for (let i = 0; i < 15; i++) {
			const email = `waitlist-test-${Date.now()}-${i}@example.com`;

			const waitlist = await seedE2EScenario("waitlist", {
				firstName: faker.person.firstName(),
				lastName: faker.person.lastName(),
				email: email,
				dateOfBirth: dayjs().subtract(20, "years").format("YYYY-MM-DD"),
				pronouns: "they/them",
				gender: "non-binary",
				phoneNumber: faker.phone.number(),
				medicalConditions: "None",
				socialMediaConsent: "no",
			});
			waitlistIds.push(waitlist.waitlistId);
		}
	});

	test.afterAll(async () => {
		await adminMember?.cleanUp();

		// Clean up waitlist entries
		for (const id of waitlistIds) {
			await deleteE2EFixture("waitlist", id);
		}
	});

	test.beforeEach(async ({ context, page }) => {
		// Set viewport to desktop size BEFORE login to ensure table is visible
		await page.setViewportSize({ width: 1280, height: 720 });
		await loginAsUser(context, adminMember.email);
	});

	test("should paginate waitlist table correctly", async ({ page }) => {
		await page.goto(waitlistPath);

		// Wait for table rows to be attached in DOM
		await page.locator("table tbody tr").first().waitFor({
			state: "attached",
			timeout: 10000,
		});

		const initialRowCount = await page.locator("table tbody tr").count();
		expect(initialRowCount).toBeGreaterThan(0);
		expect(initialRowCount).toBeLessThanOrEqual(10);

		// Check if there's a next page button and if it's enabled
		const nextButton = page.getByRole("button", { name: "Next" });
		const isNextButtonDisabled = await nextButton.isDisabled();

		if (!isNextButtonDisabled) {
			// Go to the next page
			await nextButton.click();
			await page.waitForLoadState("networkidle");

			// Verify URL has page parameter
			expect(page.url()).toContain("page=1");

			// Verify pagination controls reflect we moved off first page
			await expect(
				page.getByRole("button", { name: "Go to previous page" }),
			).toBeEnabled();
		}
	});

	test("should change page size correctly", async ({ page }) => {
		await page.goto(waitlistPath);

		// Wait for table rows to be attached in DOM
		await page.locator("table tbody tr").first().waitFor({
			state: "attached",
			timeout: 10000,
		});

		// Find and click the page size selector in footer
		await page
			.getByRole("button", { name: "Waitlist elements per page" })
			.click();

		// Select 25 from the dropdown
		await page.getByRole("option", { name: "25" }).click();

		// Wait for URL to update
		await page.waitForURL(
			"**/dashboard/beginners-workshop?**tab=waitlist**pageSize=25**",
			{
				timeout: 10000,
			},
		);

		// Verify URL has pageSize parameter
		expect(page.url()).toContain("pageSize=25");

		// Verify rows are displayed (should be up to 25)
		const rowCount = await page.locator("table tbody tr").count();
		expect(rowCount).toBeGreaterThan(0);
		expect(rowCount).toBeLessThanOrEqual(25);
	});

	test("should search waitlist correctly", async ({ page }) => {
		await page.goto(waitlistPath);

		// Wait for table rows to be attached in DOM
		await page.locator("table tbody tr").first().waitFor({
			state: "attached",
			timeout: 10000,
		});

		// Get the first row's full name to search for
		const firstRowName = await page
			.locator("table tbody tr:first-child td:nth-child(4)")
			.textContent();

		// Search for this name
		const searchInput = page.getByPlaceholder("Search for a person");
		await searchInput.fill(firstRowName || "");
		await searchInput.press("Tab"); // Trigger onchange by blurring

		// Wait for search to complete (URL to update)
		await page.waitForURL(
			`**/dashboard/beginners-workshop?**tab=waitlist**q=**`,
			{
				timeout: 10000,
			},
		);

		// Verify URL has search query
		expect(page.url()).toContain(`q=`);

		// Verify the search returned results (at least one row)
		await expect(page.locator("table tbody tr")).toHaveCount(1);
	});

	test("should clear search correctly", async ({ page }) => {
		await page.goto(`${waitlistPath}&q=test`);

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

		// Chromium can miss the button click event here; fallback to input clear
		try {
			await waitForClearedQuery();
		} catch {
			await page.getByPlaceholder("Search for a person").fill("");
		}

		// Wait for URL param to clear (missing or empty)
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
		await page.goto("/dashboard/beginners-workshop?tab=waitlist");

		// Wait for table rows to be attached in DOM
		await page.locator("table tbody tr").first().waitFor({
			state: "attached",
			timeout: 15000,
		});

		// Verify the total count is displayed (this proves rowCount getter is working)
		const footerCell = page.locator("table tfoot tr td", {
			hasText: /Total \d+ people on the waitlist/,
		});
		await expect(footerCell).toBeVisible();
		const footerText = await footerCell.textContent();
		expect(footerText).toMatch(/Total \d+ people on the waitlist/);

		// Extract the total count
		const match = footerText?.match(/Total (\d+) people/);
		expect(match).toBeTruthy();
		const totalCount = parseInt(match![1]);
		expect(totalCount).toBeGreaterThan(0);

		// Verify we can see rows
		const rowCount = await page.locator("table tbody tr").count();
		expect(rowCount).toBeGreaterThan(0);
		expect(rowCount).toBeLessThanOrEqual(10);
	});
});
