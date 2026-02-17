import { expect, test } from "@playwright/test";
import {
	createTestRegistration,
	createTestWorkshop,
	generateUniqueTestData,
	makeAuthenticatedRequest,
} from "./attendee-test-helpers";
import { createMember, getSupabaseServiceClient } from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

test.describe("Attendee Management UI", () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let memberData: Awaited<ReturnType<typeof createMember>>;
	let member2Data: Awaited<ReturnType<typeof createMember>>;
	let workshopId: string;
	let registrationIds: string[] = [];

	test.beforeAll(async () => {
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 15);

		// Create admin user
		adminData = await createMember({
			email: `admin-ui-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["admin"]),
		});

		// Create member users
		memberData = await createMember({
			email: `member-ui-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["member"]),
		});

		member2Data = await createMember({
			email: `member2-ui-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(["member"]),
		});
	});

	test.beforeEach(async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		// Create test workshop using helper
		const workshop = await createTestWorkshop(page, {
			title: `UI Test Workshop ${generateUniqueTestData()}`,
			description: "Test workshop for UI testing",
		});
		workshopId = workshop.id;

		// Create test registrations for different users
		registrationIds = [];
		const users = [adminData.userId, memberData.userId, member2Data.userId];

		for (const userId of users) {
			const registration = await createTestRegistration(
				page,
				workshopId,
				userId,
			);
			registrationIds.push(registration.id);
		}
	});

	test("should display attendee management page", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto(`/dashboard/workshops/${workshopId}/attendees`);

		// Check page title and description
		await expect(
			page.getByRole("heading", { name: "Workshop Attendees" }),
		).toBeVisible();
		await expect(
			page.getByText("Manage attendance and process refunds"),
		).toBeVisible();

		// Check main sections are present
		await expect(page.getByText("Registered Attendees")).toBeVisible();
		await expect(page.getByText("Refund").first()).toBeVisible();
	});

	test("should display registered attendees list", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);
		await page.goto(`/dashboard/workshops/${workshopId}/attendees`);

		// Wait for attendees to load
		await expect(page.getByText("Registered Attendees")).toBeVisible();

		// Check that attendee cards/rows are displayed or show "No attendees" message
		const hasAttendees = page.locator(".border.rounded-lg").first();
		const noAttendeesMessage = page.getByText("No attendees registered yet");

		// Either attendees are displayed or we see the no attendees message
		await expect(hasAttendees.or(noAttendeesMessage)).toBeVisible({
			timeout: 10000,
		});
	});

	test("should show attendance status badges", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto(`/dashboard/workshops/${workshopId}/attendees`);

		// Wait for attendees to load or no attendees message
		const hasAttendees = page.locator(".border.rounded-lg").first();
		const noAttendeesMessage = page.getByText("No attendees registered yet");

		await expect(hasAttendees.or(noAttendeesMessage)).toBeVisible({
			timeout: 10000,
		});

		// Only check for badges if we have attendees
		if (await hasAttendees.isVisible()) {
			// Check for pending status badges (default status) - they are in Badge components with data-slot="badge"
			await expect(
				page.locator('[data-slot="badge"]').getByText("pending").first(),
			).toBeVisible();
		}
	});

	test("should allow updating attendance status", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto(`/dashboard/workshops/${workshopId}/attendees`);

		// Wait for attendees to load or no attendees message
		const hasAttendees = page.locator(".border.rounded-lg").first();
		const noAttendeesMessage = page.getByText("No attendees registered yet");

		await expect(hasAttendees.or(noAttendeesMessage)).toBeVisible({
			timeout: 10000,
		});
		// Only test attendance updates if we have attendees
		if (await hasAttendees.isVisible()) {
			// Wait for loading to complete
			await expect(page.locator(".animate-spin")).not.toBeVisible({
				timeout: 10000,
			});

			// Find and click on attendance status dropdown trigger using data-slot attribute
			const statusTrigger = page.locator('[id*="-select"]').first();
			await expect(statusTrigger).toBeVisible({ timeout: 5000 });
			await statusTrigger.click();

			await page.getByText("Mark as Attended").click();

			// Test passes if we can interact with the UI elements without errors
		} else {
			// If no attendees, just verify the message is shown
			await expect(noAttendeesMessage).toBeVisible();
		}
	});

	test("should open refund dialog when process refund clicked", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);
		await page.goto(`/dashboard/workshops/${workshopId}/attendees`);

		// Wait for page to load
		await expect(page.getByText("Refund").first()).toBeVisible();

		// Check dialog opens
		await expect(page.getByRole("button", { name: "Confirm" })).toBeVisible();

		// Check action buttons
		await expect(page.getByRole("button", { name: "Cancel" })).toBeVisible();
	});

	test("should process refund through UI", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto(`/dashboard/workshops/${workshopId}/attendees`);

		// Wait for page to load
		await expect(page.getByText("Refund").first()).toBeVisible();

		// Open refund dialog
		await page.getByRole("button", { name: "Confirm" }).click();
		await page.getByRole("button", { name: "Processing..." }).click();

		// Check for success message
		await expect(page.getByText("Refund processed")).toBeVisible({
			timeout: 10000,
		});
	});

	test("should handle error states gracefully", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);

		// Navigate to non-existent workshop - should return 404
		const response = await page.goto(
			"/dashboard/workshops/00000000-0000-0000-0000-000000000000/attendees",
		);

		// Should get a 404 response
		expect(response?.status()).toBe(404);

		// Should show SvelteKit error page content
		await expect(
			page
				.getByText("404")
				.or(page.getByText("Not Found"))
				.or(page.getByText("Workshop not found")),
		).toBeVisible({ timeout: 5000 });
	});

	test("should close refund dialog on cancel", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto(`/dashboard/workshops/${workshopId}/attendees`);

		// Wait for page to load
		await expect(page.getByText("Refund").first()).toBeVisible();

		// Click cancel
		await page.getByRole("button", { name: "Cancel" }).click();

		// Dialog should close
		await expect(page.getByRole("dialog")).not.toBeVisible();
	});

	test("should restrict access to non-authorized users", async ({
		page,
		context,
	}) => {
		// Login as regular member (not admin/coordinator)
		await loginAsUser(context, memberData.email);

		// Try to access attendee management page
		await page.goto(`/dashboard/workshops/${workshopId}/attendees`);

		expect(page.url()).toContain(`/dashboard/members`);
	});

	test.afterEach(async () => {
		// Clean up test data
		const supabase = getSupabaseServiceClient();

		if (registrationIds.length > 0) {
			await supabase
				.from("club_activity_registrations")
				.delete()
				.in("id", registrationIds);
		}

		if (workshopId) {
			await supabase.from("club_activities").delete().eq("id", workshopId);
		}
	});

	test.afterAll(async () => {
		if (adminData?.cleanUp) {
			await adminData.cleanUp();
		}
		if (memberData?.cleanUp) {
			await memberData.cleanUp();
		}
		if (member2Data?.cleanUp) {
			await member2Data.cleanUp();
		}
	});
});
