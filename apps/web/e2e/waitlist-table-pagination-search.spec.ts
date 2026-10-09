import { faker } from "@faker-js/faker";
import { expect, test } from "@playwright/test";
import dayjs from "dayjs";
import { deleteE2EFixture, seedE2EScenario } from "./e2eApi";
import { createMember } from "./setupFunctions";
import { loginAsUser } from "./auth";
import { gotoHydrated } from "./hydration";

test.describe("Waitlist table pagination and search", () => {
	let adminMember: Awaited<ReturnType<typeof createMember>>;
	const waitlistIds: string[] = [];
	const waitlistPath = "/dashboard/beginners-workshop?tab=waitlist";
	let searchTargetEmail = "";
	const searchTargetName = "UniqueWaitlistSearch";

	test.beforeAll(async () => {
		await seedE2EScenario("waitlistStatus", { isOpen: true });

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
			if (i === 0) searchTargetEmail = email;

			const waitlist = await seedE2EScenario("waitlist", {
				firstName: i === 0 ? searchTargetName : faker.person.firstName(),
				lastName: faker.person.lastName(),
				email: email,
				dateOfBirth: dayjs().subtract(20, "years").format("YYYY-MM-DD"),
				pronouns: "they/them",
				gender: "non-binary",
				phoneNumber: "+353810000000",
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

			// Verify URL has the next cursor.
			await expect
				.poll(() => new URL(page.url()).searchParams.get("cursor") ?? "")
				.not.toBe("");

			// Verify pagination controls reflect we moved off first page
			await expect(
				page.getByRole("button", { name: "Previous" }),
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

		const searchInput = page.getByPlaceholder("Search for a person");
		await searchInput.fill(searchTargetName);

		// Verify URL has search query
		await expect
			.poll(() => new URL(page.url()).searchParams.get("q") ?? "")
			.toBe(searchTargetName);

		await expect(
			page.getByRole("link", { name: searchTargetEmail, exact: true }),
		).toBeVisible();
	});

	test("should clear search correctly", async ({ page }) => {
		await gotoHydrated(page, `${waitlistPath}&q=test`);

		const searchInput = page.getByPlaceholder("Search for a person");
		await expect(searchInput).toHaveValue("test");

		await page.getByRole("button", { name: "Clear search" }).click();

		await expect
			.poll(() => new URL(page.url()).searchParams.get("q") ?? "", {
				timeout: 10000,
			})
			.toBe("");
		await expect(searchInput).toHaveValue("");
	});

	test("should display correct total count for pagination", async ({
		page,
	}) => {
		await gotoHydrated(page, waitlistPath);

		// Wait for table rows to be attached in DOM
		await page.locator("table tbody tr").first().waitFor({
			state: "attached",
			timeout: 15000,
		});

		// The footer counts the whole waitlist, not just the visible page; this
		// suite seeds 15 entries, so at least that many exist across pages.
		const footerCell = page.locator("table tfoot tr td", {
			hasText: /Total \d+ people waiting/,
		});
		await expect(footerCell).toBeVisible();
		const total = Number(
			(await footerCell.textContent())?.match(/Total (\d+) people/)?.[1],
		);
		expect(total).toBeGreaterThanOrEqual(waitlistIds.length);

		const rowCount = await page.locator("table tbody tr").count();
		expect(rowCount).toBeGreaterThan(0);
		expect(rowCount).toBeLessThanOrEqual(10);
	});
});
