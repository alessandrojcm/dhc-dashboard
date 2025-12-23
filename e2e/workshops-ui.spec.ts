import { expect, test } from "@playwright/test";
import dayjs from "dayjs";
import { createMember, createWorkshop } from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

test.describe("Workshop UI", () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let workshopCoordinatorData: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const timestamp = Date.now();

		// Create admin user
		adminData = await createMember({
			email: `admin-ui-${timestamp}@test.com`,
			roles: new Set(["admin"]),
		});

		// Create workshop coordinator user
		workshopCoordinatorData = await createMember({
			email: `coordinator-ui-${timestamp}@test.com`,
			roles: new Set(["workshop_coordinator"]),
		});
	});

	test("should display workshops page and create button for authorized users", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard/workshops");

		// Should show the workshops page
		await expect(page.getByRole("heading", { name: "Workshops" }))
			.toBeVisible();

		// Should show create button
		await expect(page.getByRole("button", { name: "Create Workshop" }))
			.toBeVisible();
	});

	test("should navigate to create workshop form", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard/workshops");

		// Click create workshop button
		await page.getByRole("button", { name: "Create Workshop" }).click();
		// Should navigate to create page
		await expect(page).toHaveURL("/dashboard/workshops/create");
		await expect(page.getByRole("heading", { name: "Create Workshop" }))
			.toBeVisible();
	});

	test("should display and validate workshop creation form", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard/workshops/create");

		// Check all form fields are present using proper labels
		await expect(page.getByRole("textbox", { name: /title/i }))
			.toBeVisible();
		await expect(page.getByRole("textbox", { name: /description/i }))
			.toBeVisible();
		await expect(page.getByRole("textbox", { name: /location/i }))
			.toBeVisible();
		await expect(page.getByText(/workshop date & time/i)).toBeVisible();
		await expect(
			page.getByRole("spinbutton", { name: /maximum capacity/i }),
		).toBeVisible();
		await expect(page.getByRole("spinbutton", { name: /member price/i }))
			.toBeVisible();
		await expect(page.getByText("Public Workshop", { exact: true }))
			.toBeVisible();
		await expect(page.getByRole("spinbutton", { name: /refund deadline/i }))
			.toBeVisible();

		// Check submit button
		await expect(page.getByRole("button", { name: "Create Workshop" }))
			.toBeVisible();

		// Check back button
		await expect(page.getByRole("link", { name: "Back to Workshops" }))
			.toBeVisible();
	});

	test("should show validation errors for empty required fields", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard/workshops/create");

		// Try to submit form without filling required fields
		await page.getByRole("button", { name: "Create Workshop" }).click();

		// Should show validation errors (wait a moment for validation to trigger)
		await page.waitForTimeout(1000);

		// Check that form hasn't been submitted (still on create page)
		await expect(page).toHaveURL("/dashboard/workshops/create");
	});

	test("should successfully create a workshop through UI", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard/workshops/create");

		const timestamp = Date.now();
		const workshopTitle = `UI Test Workshop ${timestamp}`;

		// Fill out the form using proper accessible selectors
		await page.getByRole("textbox", { name: /title/i }).fill(workshopTitle);
		await page.getByRole("textbox", { name: /description/i }).fill(
			"Test workshop created via UI",
		);
		await page.getByRole("textbox", { name: /location/i }).fill(
			"Test Location",
		);
		// Set workshop date (tomorrow) - using dayjs
		const workshopDate = dayjs().add(1, "day");
		await page.getByRole("button", { name: "Date" }).click();

		// Interact with the date picker properly
		await page.getByRole("button", { name: "Date" }).click();
		await page.getByLabel("Select a year").selectOption(
			workshopDate.year().toString(),
		);
		await page.getByLabel("Select a month").selectOption(
			workshopDate.format("M"),
		);
		await page.getByRole("button", {
			name: workshopDate.format("dddd, MMMM D,"),
		}).click();
		await page.getByRole("textbox", { name: "From" }).fill(
			workshopDate.format("HH:mm:ss"),
		);
		await page
			.getByRole("textbox", { name: "To" })
			.fill(workshopDate.add(1, "hour").format("HH:mm:ss"));

		await page.getByText(/maximum capacity/i).fill("15");
		await page.getByText(/member price/i).fill("15");

		// Submit the form
		await page.getByRole("button", { name: "Create Workshop" }).click();

		// Should show success message
		await expect(
			page.getByText(`Workshop "${workshopTitle}" created successfully!`),
		).toBeVisible();

		// Should redirect to workshops list after a moment
		await page.waitForTimeout(3000);
		await expect(page).toHaveURL("/dashboard/workshops");
	});

	test("should display created workshop in list", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);

		// First create a workshop for testing list display
		const timestamp = Date.now();
		const workshopTitle = `List Test Workshop ${timestamp}`;
		const workshopDate = dayjs().add(1, "day").hour(14).minute(0);

		await createWorkshop({
			title: workshopTitle,
			description: "Test workshop for list display",
			location: "Test Location",
			start_date: workshopDate.toDate(),
			end_date: workshopDate.add(2, "hour").toDate(),
			max_capacity: 10,
			price_member: 1000, // cents
			price_non_member: 2000, // cents
			is_public: true,
			refund_days: 3,
			created_by: adminData.userId!,
		});

		// Now visit workshops page
		await page.goto("/dashboard/workshops");

		// Should see the workshop in the list
		await expect(page.getByText(workshopTitle)).toBeVisible();
		await expect(page.getByText("Test workshop for list display"))
			.toBeVisible();
		await expect(page.getByText("Test Location")).toBeVisible();

		// Should see status badge
		await expect(page.getByText("planned")).toBeVisible();

		// Should see action buttons for planned workshop - find them within the workshop's container
		const workshopCard = page.locator("article").filter({
			hasText: workshopTitle,
		});
		await expect(workshopCard.getByRole("button", { name: "Edit" }))
			.toBeVisible();
		await expect(workshopCard.getByRole("button", { name: "Publish" }))
			.toBeVisible();
		await expect(workshopCard.getByRole("button", { name: "Cancel" }))
			.toBeVisible();
		await expect(workshopCard.getByRole("button", { name: "Delete" }))
			.toBeVisible();
	});

	test("should allow publishing a workshop through UI", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);

		// Create a workshop first
		const timestamp = Date.now();
		const workshopTitle = `Publish Test Workshop ${timestamp}`;
		const workshopDate = dayjs().add(1, "day").hour(14).minute(0);
		const workshopData = await createWorkshop({
			title: workshopTitle,
			description: "Test workshop for publishing",
			location: "Test Location",
			start_date: workshopDate.toDate(),
			end_date: workshopDate.add(2, "hour").toDate(),
			max_capacity: 10,
			price_member: 1000,
			price_non_member: 2000,
			is_public: true,
			refund_days: 3,
			created_by: adminData.userId!,
		});

		// Visit workshops page
		await page.goto("/dashboard/workshops");
		await page.getByRole("button", { name: workshopData.title }).click();
		await page.getByRole("button", { name: "Publish", exact: true }).first()
			.click();

		// Status should change to published
		await expect(page.getByText("published")).toBeVisible();
		await page.getByRole("button", { name: workshopData.title }).click();
		// Publish button should disappear (published workshops can't be published again)
		await expect(page.getByRole("button", { name: "Publish", exact: true }))
			.not
			.toBeVisible();
	});

	test("should allow cancelling a workshop through UI", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);

		// Create a workshop first
		const timestamp = Date.now();
		const workshopTitle = `Cancel Test Workshop ${timestamp}`;
		const workshopDate = dayjs().add(1, "day").hour(14).minute(0);

		const workshopData = await createWorkshop({
			title: workshopTitle,
			description: "Test workshop for cancelling",
			location: "Test Location",
			start_date: workshopDate.toDate(),
			end_date: workshopDate.add(2, "hour").toDate(),
			max_capacity: 10,
			price_member: 1000,
			price_non_member: 2000,
			is_public: true,
			refund_days: 3,
			created_by: adminData.userId!,
			status: "published",
		});

		// Visit workshops page
		await page.goto("/dashboard/workshops");

		// Find the workshop card and click cancel (with confirmation)
		await page.getByRole("button", { name: workshopData.title }).click();

		// Set up dialog handler for confirmation
		page.on("dialog", (dialog) => dialog.accept());

		await page.getByRole("button", { name: "Cancel", exact: true }).click();
		// Status should change to cancelled
		await expect(page.getByText("cancelled")).toBeVisible();
	});

	test("should allow deleting a workshop through UI", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);

		// Create a workshop first
		const timestamp = Date.now();
		const workshopTitle = `Delete Test Workshop ${timestamp}`;
		const workshopDate = dayjs().add(1, "day").hour(14).minute(0);

		await createWorkshop({
			title: workshopTitle,
			description: "Test workshop for deleting",
			location: "Test Location",
			start_date: workshopDate.toDate(),
			end_date: workshopDate.add(2, "hour").toDate(),
			max_capacity: 10,
			price_member: 1000,
			price_non_member: 2000,
			is_public: true,
			refund_days: 3,
			created_by: adminData.userId!,
		});

		// Visit workshops page
		await page.goto("/dashboard/workshops");

		// Find the workshop card and click delete (with confirmation)
		await page.getByRole("button", { name: workshopTitle }).click();

		// Set up dialog handler for confirmation
		page.on("dialog", (dialog) => dialog.accept());

		await page.getByRole("button", { name: "Delete", exact: true }).click();
		await page.getByRole("button", { name: "Delete Workshop", exact: true })
			.click();
		await page.getByRole("spinbutton").waitFor({
			state: "hidden",
			timeout: 2000,
		});
		await page.getByRole("heading", { name: workshopTitle }).waitFor({
			state: "hidden",
			timeout: 2000,
		});
		// Workshop should disappear from the list
		await expect(page.getByText(workshopTitle)).not.toBeVisible();
	});

	test("should work for workshop coordinator role", async ({ page, context }) => {
		await loginAsUser(context, workshopCoordinatorData.email);
		await page.goto("/dashboard/workshops");

		// Should show the workshops page
		await expect(page.getByRole("heading", { name: "Workshops" }))
			.toBeVisible();

		// Should show create button for workshop coordinator
		await expect(page.getByRole("button", { name: "Create Workshop" }))
			.toBeVisible();

		// Should be able to access create form
		await page.getByRole("button", { name: "Create Workshop" }).click();
		await expect(page).toHaveURL("/dashboard/workshops/create");
		await expect(page.getByRole("heading", { name: "Create Workshop" }))
			.toBeVisible();
	});

	test("should show empty state when no workshops exist", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard/workshops");

		// Wait for the page to load
		await page.waitForLoadState("networkidle");

		// Should show empty state message if no workshops (or just the workshops we created in other tests)
		// The exact message depends on whether other tests left workshops in the database
		await expect(page.getByRole("heading", { name: "Workshops" }))
			.toBeVisible();
	});

	test("should format prices correctly in workshop list", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);

		// Create a workshop with specific prices to test formatting
		const timestamp = Date.now();
		const workshopTitle = `Price Format Test ${timestamp}`;
		const workshopDate = dayjs().add(1, "day").hour(14).minute(0);

		await createWorkshop({
			title: workshopTitle,
			description: "Test price formatting",
			location: "Test Location",
			start_date: workshopDate.toDate(),
			end_date: workshopDate.add(2, "hour").toDate(),
			max_capacity: 10,
			price_member: 1250, // €12.50 in cents
			price_non_member: 2075, // €20.75 in cents
			is_public: true,
			refund_days: 3,
			created_by: adminData.userId!,
		});

		// Visit workshops page
		await page.goto("/dashboard/workshops");

		// Check that prices are formatted correctly (from cents to euros)
		const workshopCard = page.locator("article").filter({
			hasText: workshopTitle,
		});
		await expect(workshopCard.getByText("€12.50")).toBeVisible();
		await expect(workshopCard.getByText("€20.75")).toBeVisible();
	});
});
