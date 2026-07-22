import { expect, test } from "@playwright/test";
import {
	createTestRegistration,
	createTestWorkshop,
} from "./attendee-test-helpers";
import { createMember, getSupabaseServiceClient } from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

test.describe("Workshop Edit Feature", () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let workshopCoordinatorData: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const timestamp = Date.now();

		// Create admin user
		adminData = await createMember({
			email: `admin-edit-${timestamp}@test.com`,
			roles: new Set(["admin"]),
		});

		// Create workshop coordinator user
		workshopCoordinatorData = await createMember({
			email: `coordinator-edit-${timestamp}@test.com`,
			roles: new Set(["workshop_coordinator"]),
		});
	});

	test("should allow editing a planned workshop through UI", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);

		const timestamp = Date.now();
		const originalTitle = `Original Workshop ${timestamp}`;
		const updatedTitle = `Updated Workshop ${timestamp}`;

		// Create a workshop using the helper function (creates directly in database)
		const workshop = await createTestWorkshop(page, {
			title: originalTitle,
			description: "Original description",
			location: "Original Location",
			max_capacity: 10,
			price_member: 1500,
			price_non_member: 2500,
			is_public: true,
		});
		const workshopId = workshop.id;

		// Update the workshop status to 'planned' so it can be edited
		const supabase = getSupabaseServiceClient();
		await supabase
			.from("club_activities")
			.update({ status: "planned" })
			.eq("id", workshopId);

		// Navigate to workshops page
		await page.goto("/dashboard/workshops");
		await expect(
			page.getByRole("heading", { name: "Workshops" }),
		).toBeVisible();

		// Find and click on the created workshop to open modal
		await page.getByText(originalTitle).click();

		// Wait for modal to open and click edit button
		await expect(page.getByRole("dialog")).toBeVisible();
		await page.getByTestId("edit-workshop-button").click();

		// Should navigate to edit page
		await expect(page).toHaveURL(`/dashboard/workshops/${workshopId}/edit`);
		await expect(
			page.getByRole("heading", { name: "Edit Workshop" }),
		).toBeVisible();

		// Verify form is pre-populated with existing data
		await expect(page.getByRole("textbox", { name: /title/i })).toHaveValue(
			originalTitle,
		);
		await expect(
			page.getByRole("textbox", { name: /description/i }),
		).toHaveValue("Original description");
		await expect(page.getByRole("textbox", { name: /location/i })).toHaveValue(
			"Original Location",
		);
		await expect(
			page.getByRole("spinbutton", { name: /maximum capacity/i }),
		).toHaveValue("10");
		await expect(
			page.getByRole("spinbutton", { name: "Member Price", exact: true }),
		).toHaveValue("15");
		await expect(
			page.getByRole("spinbutton", { name: /non-member price/i }),
		).toHaveValue("25");

		// Update the workshop details
		await page.getByRole("textbox", { name: /title/i }).fill(updatedTitle);
		await page
			.getByRole("textbox", { name: /description/i })
			.fill("Updated description");
		await page
			.getByRole("textbox", { name: /location/i })
			.fill("Updated Location");
		await page
			.getByRole("spinbutton", { name: /maximum capacity/i })
			.fill("15");
		await page
			.getByRole("spinbutton", {
				name: "Member Price",
				exact: true,
			})
			.fill("20");
		await page
			.getByRole("spinbutton", { name: /non-member price/i })
			.fill("30");

		// Submit the form
		await page.getByRole("button", { name: "Update Workshop" }).click();

		// Should show success message
		await expect(page.getByText(/updated successfully/i)).toBeVisible();

		// Should redirect back to workshops page after delay
		await page.waitForTimeout(2500);
		await expect(page).toHaveURL("/dashboard/workshops");

		// Verify the workshop was updated by checking the title in the list
		await expect(page.getByText(updatedTitle)).toBeVisible();
	});

	test("should prevent editing published workshops", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);

		const timestamp = Date.now();
		const workshopTitle = `Published Workshop ${timestamp}`;

		// Create a workshop using the helper function (creates as 'published' by default)
		const workshop = await createTestWorkshop(page, {
			title: workshopTitle,
			description: "Test description",
			location: "Test Location",
			max_capacity: 10,
			price_member: 15,
			is_public: false,
		});
		const workshopId = workshop.id;

		// Navigate directly to edit page
		await page.goto(`/dashboard/workshops/${workshopId}/edit`);

		// Should show warning that workshop cannot be edited
		await expect(
			page.getByText(
				/this workshop cannot be edited because it has been published/i,
			),
		).toBeVisible();

		// Form fields should be disabled
		await expect(page.getByRole("textbox", { name: /title/i })).toBeDisabled();
		await expect(
			page.getByRole("textbox", { name: /description/i }),
		).toBeDisabled();
		await expect(
			page.getByRole("textbox", { name: /location/i }),
		).toBeDisabled();

		// Submit button should be disabled
		await expect(
			page.getByRole("button", { name: "Update Workshop" }),
		).toBeDisabled();
	});

	test("should prevent pricing changes when attendees are registered", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);

		const timestamp = Date.now();
		const workshopTitle = `Workshop With Attendees ${timestamp}`;

		// Create a workshop using the helper function (creates as 'published' by default)
		const workshop = await createTestWorkshop(page, {
			title: workshopTitle,
			description: "Test description",
			location: "Test Location",
			max_capacity: 10,
			price_member: 15,
			is_public: false,
		});
		const workshopId = workshop.id;

		// Register the admin user for the workshop
		await createTestRegistration(page, workshopId, adminData.userId);

		// Navigate to edit page
		await page.goto(`/dashboard/workshops/${workshopId}/edit`);
		await page
			.getByText(
				"Pricing cannot be changed because there are already registered attendees.",
			)
			.scrollIntoViewIfNeeded();
		// Should show warning about pricing restrictions
		await expect(
			page.getByText(
				"Pricing cannot be changed because there are already registered attendees.",
			),
		).toBeVisible();

		// Pricing fields should be disabled
		await expect(
			page.getByRole("spinbutton", { name: /member price/i }),
		).toBeDisabled();
	});

	test("should show validation errors for invalid data", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminData.email);

		const timestamp = Date.now();
		const workshopTitle = `Validation Test Workshop ${timestamp}`;

		// Create a workshop using the helper function
		const workshop = await createTestWorkshop(page, {
			title: workshopTitle,
			description: "Test description",
			location: "Test Location",
			max_capacity: 10,
			price_member: 15,
			is_public: false,
		});
		const workshopId = workshop.id;

		// Update the workshop status to 'planned' so it can be edited
		const supabase = getSupabaseServiceClient();
		await supabase
			.from("club_activities")
			.update({ status: "planned" })
			.eq("id", workshopId);

		// Navigate to edit page
		await page.goto(`/dashboard/workshops/${workshopId}/edit`);

		// Clear required fields
		await page.getByRole("textbox", { name: /title/i }).fill("");
		await page.getByRole("textbox", { name: /location/i }).fill("");

		// Try to submit
		await page.getByRole("button", { name: "Update Workshop" }).click();
		await page.getByText("Location is required.").scrollIntoViewIfNeeded();
		await page.getByText("Title is required.").scrollIntoViewIfNeeded();
		// Should stay on edit page due to validation errors
		await expect(page.getByText("Location is required.")).toBeVisible();
		await expect(page.getByText("Title is required.")).toBeVisible();
	});

	test("should allow workshop coordinator to edit workshops", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, workshopCoordinatorData.email);

		const timestamp = Date.now();
		const workshopTitle = `Coordinator Workshop ${timestamp}`;

		// Create a workshop using the helper function (creates directly in database)
		const workshop = await createTestWorkshop(page, {
			title: workshopTitle,
			description: "Coordinator test",
			location: "Test Location",
			max_capacity: 8,
			price_member: 12,
			is_public: false,
		});
		const workshopId = workshop.id;

		// Update the workshop status to 'planned' so it can be edited
		const supabase = getSupabaseServiceClient();
		await supabase
			.from("club_activities")
			.update({ status: "planned" })
			.eq("id", workshopId);

		// Navigate to edit page
		await page.goto(`/dashboard/workshops/${workshopId}/edit`);

		// Should be able to access edit page
		await expect(
			page.getByRole("heading", { name: "Edit Workshop" }),
		).toBeVisible();

		// Should be able to edit the workshop
		const updatedTitle = `Updated ${workshopTitle}`;
		await page.getByRole("textbox", { name: /title/i }).fill(updatedTitle);
		await page.getByRole("button", { name: "Update Workshop" }).click();

		// Should show success message
		await expect(page.getByText(/updated successfully/i)).toBeVisible();
	});
});
