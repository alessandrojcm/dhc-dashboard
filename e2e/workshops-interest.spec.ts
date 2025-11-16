import { expect, test, type Page } from "@playwright/test";
import { createMember, getSupabaseServiceClient } from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

test.describe("Workshop Interest System", () => {
	let workshopId: string;
	let memberData: Awaited<ReturnType<typeof createMember>>;
	let adminData: Awaited<ReturnType<typeof createMember>>;
	const timestamp = Date.now();

	test.beforeAll(async () => {
		const randomSuffix = Math.random().toString(36).substring(2, 15);

		// Create member user
		memberData = await createMember({
			email: `member-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["member"]),
		});

		// Create admin user for workshop creation
		adminData = await createMember({
			email: `admin-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["admin"]),
		});
	});

	async function makeAuthenticatedRequest(
		page: Page,
		url: string,
		options: {
			method?: string;
			data?: unknown;
			headers?: Record<string, string>;
			body?: string;
		} = {},
	) {
		const response = await page.request.fetch(url, {
			...options,
			headers: {
				"Content-Type": "application/json",
				...options.headers,
			},
		});

		if (!response.ok()) {
			const errorText = await response.text();
			console.error(`API Error ${response.status()}: ${errorText}`);
			throw new Error(
				`HTTP ${response.status()}: ${response.statusText()} - ${errorText}`,
			);
		}

		return await response.json();
	}

	test.beforeEach(async () => {
		// Create a test workshop directly in the database to bypass API validation issues
		const supabase = getSupabaseServiceClient();
		const workshopStartDate = new Date(Date.now() + 86400000);
		const workshopEndDate = new Date(
			workshopStartDate.getTime() + 2 * 60 * 60 * 1000,
		);

		const { data: workshop, error } = await supabase
			.from("club_activities")
			.insert({
				title: `Test Workshop ${timestamp}`,
				description: "Test workshop for interest system",
				location: "Test Location",
				start_date: workshopStartDate.toISOString(),
				end_date: workshopEndDate.toISOString(),
				max_capacity: 20,
				price_member: 1000, // 10 euros in cents
				price_non_member: 2000, // 20 euros in cents
				is_public: true,
				refund_days: 3,
				status: "planned",
			})
			.select()
			.single();

		if (error) {
			throw new Error(`Failed to create test workshop: ${error.message}`);
		}

		workshopId = workshop.id;
	});

	test("should display planned workshops in calendar view", async ({
		page,
		context,
	}) => {
		// Switch to member user for the test
		await loginAsUser(context, memberData.email);
		await page.goto("/dashboard/my-workshops");

		// Take a screenshot to see what's on the page
		await page.screenshot({ path: "debug-my-workshops-page.png" });

		// Check if we're redirected or if the page loads
		console.log("Current URL:", page.url());
		console.log("Page title:", await page.title());

		// Check what's actually on the page
		const pageContent = await page.content();
		console.log("Page content contains h1:", pageContent.includes("<h1"));
		console.log(
			"Page content contains My Workshops:",
			pageContent.includes("My Workshops"),
		);

		// Check if there are any console errors
		const errors = [];
		page.on("console", (msg) => {
			if (msg.type() === "error") {
				errors.push(msg.text());
			}
		});

		// Wait a bit for the page to fully load
		await page.waitForTimeout(2000);

		if (errors.length > 0) {
			console.log("Console errors:", errors);
		}

		// Wait for the page to load and check if the basic structure is there
		await expect(page.locator('h1:has-text("My Workshops")')).toBeVisible();

		// Check if workshops are loaded in the list view first (easier to debug)
		await expect(page.locator(`text=Test Workshop ${timestamp}`)).toBeVisible();

		// Check interest count is displayed
		await expect(page.locator("text=0 interested")).toBeVisible();
	});

	test("should allow member to express interest", async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto("/dashboard/my-workshops");

		// Find and click express interest button
		await page.click(`text=Express Interest`);

		// Check success message
		await expect(
			page.locator("text=Interest expressed successfully"),
		).toBeVisible();

		// Check button text changes
		await expect(page.locator("text=Interested")).toBeVisible();

		// Check interest count updates
		await expect(page.locator("text=1 interested")).toBeVisible();
	});

	test("should allow member to withdraw interest", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, memberData.email);
		await page.goto("/dashboard");

		// First express interest
		await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/interest`,
			{
				method: "POST",
			},
		);

		await page.goto("/dashboard/my-workshops");

		// Click to withdraw interest
		await page.click("text=Interested");

		// Check success message
		await expect(
			page.locator("text=Interest withdrawn successfully"),
		).toBeVisible();

		// Check button text changes back
		await expect(page.locator("text=Express Interest")).toBeVisible();

		// Check interest count updates
		await expect(page.locator("text=0 interested")).toBeVisible();
	});

	test("should prevent duplicate interest entries", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, memberData.email);
		await page.goto("/dashboard");

		// Express interest via API
		const response1 = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/interest`,
			{
				method: "POST",
			},
		);
		expect(response1.success).toBe(true);

		// Try to express interest again - should withdraw instead
		const response2 = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/interest`,
			{
				method: "POST",
			},
		);
		expect(response2.success).toBe(true);
		expect(response2.interest).toBe(null);
		expect(response2.message).toBe("Interest withdrawn successfully");
	});

	test("should not allow interest in published workshops", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, memberData.email);
		await page.goto("/dashboard");

		// Publish the workshop
		await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/publish`,
			{
				method: "POST",
			},
		);

		// Try to express interest - this should fail
		try {
			const response = await makeAuthenticatedRequest(
				page,
				`/api/workshops/${workshopId}/interest`,
				{
					method: "POST",
				},
			);
			// If we get here, the request didn't fail as expected
			expect(response.success).toBe(false);
		} catch (error) {
			// The API call should throw an error for this case
			expect(error.message).toContain("400");
		}
	});

	test("should show interest counts to coordinators", async ({
		page,
		context,
	}) => {
		// First, switch to member user to express interest
		await loginAsUser(context, memberData.email);
		await page.goto("/dashboard");

		// Express interest as regular user
		await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/interest`,
			{
				method: "POST",
			},
		);

		// Switch back to admin (coordinator) to view interest counts
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard/workshops");

		// Check interest count is visible to coordinators
		await expect(page.locator("text=1 interested")).toBeVisible();
	});
});
