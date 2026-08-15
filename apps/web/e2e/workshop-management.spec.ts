import { expect, test } from "@playwright/test";
import dayjs from "dayjs";
import {
	createTestRegistration,
	createTestWorkshop,
} from "./attendee-test-helpers";
import { createMember, createWorkshop } from "./setupFunctions";
import { deleteE2EFixture, seedE2EScenario } from "./e2eApi";
import type { E2ERegistrationSeedRequest } from "./e2eApi";
import { loginAsUser } from "./auth";
import { gotoHydrated } from "./hydration";

// Consolidated workshop management E2E covering the list/calendar, create form,
// edit form (incl. published-lock and pricing-lock), modal publish/cancel/delete
// actions, and the attendee management page (check-in + refund popover).
// Replaces workshops-ui.spec.ts, workshop-edit.spec.ts, attendee-management-ui.spec.ts
// and the skipped attendance-management / refund-management / workshop-full-lifecycle stubs.

const NON_EXISTENT_WORKSHOP_ID = "00000000-0000-0000-0000-000000000000";

// Calendar25 date picker interaction. dayjs date must be in the future.
async function pickWorkshopDate(
	page: import("@playwright/test").Page,
	date: dayjs.Dayjs,
) {
	await expect(page.getByTestId("workshop-date-time-picker")).toHaveAttribute(
		"data-hydrated",
		"true",
	);
	const dateTrigger = page.getByRole("button", { name: "Date", exact: true });
	await dateTrigger.click();
	await expect(page.getByLabel("Select a year")).toBeVisible();
	await page.getByLabel("Select a year").selectOption(date.year().toString());
	await page.getByLabel("Select a month").selectOption(date.format("M"));
	await page
		.getByRole("button", { name: date.format("dddd, MMMM D,") })
		.click();
	await page
		.getByRole("textbox", { name: "From" })
		.fill(date.format("HH:mm:ss"));
	await page
		.getByRole("textbox", { name: "To" })
		.fill(date.add(1, "hour").format("HH:mm:ss"));
}

// Open the workshop event modal by clicking the calendar event button whose
// accessible name starts with the title. Calendar events render as <button>s.
async function openWorkshopModal(
	page: import("@playwright/test").Page,
	title: string,
) {
	const eventButton = page.getByRole("button", { name: title });
	await expect(eventButton).toBeVisible();
	await eventButton.click();
	const dialog = page.getByRole("dialog");
	await expect(dialog).toBeVisible();
	return dialog;
}

test.describe("Workshop Management", () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let coordinatorData: Awaited<ReturnType<typeof createMember>>;
	let memberData: Awaited<ReturnType<typeof createMember>>;
	const createdWorkshopIds: string[] = [];
	const createdRegistrationIds: string[] = [];

	test.beforeAll(async () => {
		const ts = Date.now();
		[adminData, coordinatorData, memberData] = await Promise.all([
			createMember({
				email: `admin-wm-${ts}@test.com`,
				roles: new Set(["admin"]),
			}),
			createMember({
				email: `coordinator-wm-${ts}@test.com`,
				roles: new Set(["workshop_coordinator"]),
			}),
			createMember({
				email: `member-wm-${ts}@test.com`,
				roles: new Set(["member"]),
			}),
		]);
	});

	test.afterAll(async () => {
		// Delete registrations before workshops (FK), and workshops before
		// members (FK). Member cleanup is best-effort — the harness may 500
		// if a profile is still referenced by a cascaded row we cannot see.
		await Promise.all(
			createdRegistrationIds.map((id) =>
				deleteE2EFixture("registration", id).catch(() => {}),
			),
		);
		await Promise.all(
			createdWorkshopIds.map((id) =>
				deleteE2EFixture("workshop", id).catch(() => {}),
			),
		);
		await Promise.all([
			adminData?.cleanUp?.().catch(() => {}),
			coordinatorData?.cleanUp?.().catch(() => {}),
			memberData?.cleanUp?.().catch(() => {}),
		]);
	});

	test.describe("workshops list & calendar", () => {
		test("shows the workshops page and create button for admin", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);
			await gotoHydrated(page, "/dashboard/workshops");

			await expect(
				page.getByRole("heading", { name: "Workshops" }),
			).toBeVisible();
			await expect(
				page.getByRole("button", { name: "Create Workshop" }),
			).toBeVisible();
		});

		test("navigates to the create workshop form", async ({ page, context }) => {
			await loginAsUser(context, adminData.email);
			await gotoHydrated(page, "/dashboard/workshops");

			await page.getByRole("button", { name: "Create Workshop" }).click();

			await expect
				.poll(() => new URL(page.url()).pathname)
				.toBe("/dashboard/workshops/create");
			await expect(
				page.getByRole("heading", { name: "Create Workshop" }),
			).toBeVisible();
		});

		test("displays a seeded planned workshop in the calendar modal", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);

			const ts = Date.now();
			const title = `List Test Workshop ${ts}`;
			const start = dayjs().add(1, "day").hour(14).minute(0);
			const workshop = await createWorkshop({
				title,
				description: "Test workshop for list display",
				location: "Test Location",
				start_date: start.toDate(),
				end_date: start.add(2, "hour").toDate(),
				max_capacity: 10,
				price_member: 1000,
				price_non_member: 2000,
				is_public: true,
				refund_days: 3,
				created_by: adminData.userId!,
			});
			createdWorkshopIds.push(workshop.id);

			await gotoHydrated(page, "/dashboard/workshops");

			const dialog = await openWorkshopModal(page, title);

			await expect(dialog.getByText(title)).toBeVisible();
			await expect(
				dialog.getByText("Test workshop for list display"),
			).toBeVisible();
			await expect(dialog.getByText("Test Location")).toBeVisible();
			// Status badge uses capitalized labels.
			await expect(dialog.getByText("Planned")).toBeVisible();
			// Planned workshops show Edit / Publish / Delete (not Cancel).
			await expect(
				dialog.getByRole("button", { name: "Edit Workshop" }),
			).toBeVisible();
			await expect(
				dialog.getByRole("button", { name: "Publish" }),
			).toBeVisible();
			await expect(
				dialog.getByRole("button", { name: "Delete" }),
			).toBeVisible();
		});

		test("formats prices correctly in the modal", async ({ page, context }) => {
			await loginAsUser(context, adminData.email);

			const ts = Date.now();
			const title = `Price Format Test ${ts}`;
			const start = dayjs().add(1, "day").hour(14).minute(0);
			const workshop = await createWorkshop({
				title,
				description: "Test price formatting",
				location: "Test Location",
				start_date: start.toDate(),
				end_date: start.add(2, "hour").toDate(),
				max_capacity: 10,
				price_member: 1250, // €12.50
				price_non_member: 2075, // €20.75
				is_public: true,
				refund_days: 3,
				created_by: adminData.userId!,
			});
			createdWorkshopIds.push(workshop.id);

			await gotoHydrated(page, "/dashboard/workshops");
			const dialog = await openWorkshopModal(page, title);

			await expect(dialog.getByText("€12.50")).toBeVisible();
			await expect(dialog.getByText("€20.75")).toBeVisible();
		});

		test("works for workshop_coordinator role", async ({ page, context }) => {
			await loginAsUser(context, coordinatorData.email);
			await gotoHydrated(page, "/dashboard/workshops");

			await expect(
				page.getByRole("heading", { name: "Workshops" }),
			).toBeVisible();
			await expect(
				page.getByRole("button", { name: "Create Workshop" }),
			).toBeVisible();

			await page.getByRole("button", { name: "Create Workshop" }).click();
			await expect(page).toHaveURL("/dashboard/workshops/create");
			await expect(
				page.getByRole("heading", { name: "Create Workshop" }),
			).toBeVisible();
		});
	});

	test.describe("create workshop form", () => {
		test("displays and validates the creation form fields", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);
			await gotoHydrated(page, "/dashboard/workshops/create");

			await expect(page.getByRole("textbox", { name: /title/i })).toBeVisible();
			await expect(
				page.getByRole("textbox", { name: /description/i }),
			).toBeVisible();
			await expect(
				page.getByRole("textbox", { name: /location/i }),
			).toBeVisible();
			await expect(page.getByText(/workshop date & time/i)).toBeVisible();
			await expect(
				page.getByRole("spinbutton", { name: /maximum capacity/i }),
			).toBeVisible();
			await expect(
				page.getByRole("spinbutton", { name: /member price/i }),
			).toBeVisible();
			await expect(
				page.getByText("Public Workshop", { exact: true }),
			).toBeVisible();
			await expect(
				page.getByRole("spinbutton", { name: /refund deadline/i }),
			).toBeVisible();
			await expect(
				page.getByRole("button", { name: "Create Workshop" }),
			).toBeVisible();
			await expect(
				page.getByRole("link", { name: "Back to Workshops" }),
			).toBeVisible();
		});

		test("blocks submission with empty required fields", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);
			await gotoHydrated(page, "/dashboard/workshops/create");

			await page.getByRole("button", { name: "Create Workshop" }).click();

			// Still on the create page; server-side validation rejected the empty form.
			await expect
				.poll(() => new URL(page.url()).pathname)
				.toBe("/dashboard/workshops/create");
		});

		test("creates a workshop through the UI", async ({ page, context }) => {
			await loginAsUser(context, adminData.email);
			await gotoHydrated(page, "/dashboard/workshops/create");

			const ts = Date.now();
			const title = `UI Created Workshop ${ts}`;
			const workshopDate = dayjs().add(1, "day");

			await page.getByRole("textbox", { name: /title/i }).fill(title);
			await page
				.getByRole("textbox", { name: /description/i })
				.fill("Created via UI");
			await page
				.getByRole("textbox", { name: /location/i })
				.fill("Test Location");
			await pickWorkshopDate(page, workshopDate);
			await page
				.getByRole("spinbutton", { name: /maximum capacity/i })
				.fill("15");
			await page.getByRole("spinbutton", { name: /member price/i }).fill("15");

			await page.getByRole("button", { name: "Create Workshop" }).click();

			await expect(
				page.getByText(`Workshop "${title}" created successfully!`),
			).toBeVisible();

			// Redirects back to the list after the success delay.
			await expect(page).toHaveURL("/dashboard/workshops", { timeout: 10000 });
		});
	});

	test.describe("edit workshop form", () => {
		test("edits a planned workshop and pre-populates the form", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);

			const ts = Date.now();
			const originalTitle = `Edit Original ${ts}`;
			const updatedTitle = `Edit Updated ${ts}`;

			const workshop = await createTestWorkshop(page, {
				title: originalTitle,
				description: "Original description",
				location: "Original Location",
				max_capacity: 10,
				price_member: 1500, // cents
				price_non_member: 2500, // cents
				is_public: true,
				status: "planned",
			});
			createdWorkshopIds.push(workshop.id);

			// Open the calendar modal and click Edit Workshop.
			await gotoHydrated(page, "/dashboard/workshops");
			const dialog = await openWorkshopModal(page, originalTitle);
			await dialog.getByTestId("edit-workshop-button").click();

			await expect
				.poll(() => new URL(page.url()).pathname)
				.toBe(`/dashboard/workshops/${workshop.id}/edit`);
			await expect(
				page.getByRole("heading", { name: "Edit Workshop" }),
			).toBeVisible();

			// Pre-populated values (prices are in euros on the form).
			await expect(page.getByRole("textbox", { name: /title/i })).toHaveValue(
				originalTitle,
			);
			await expect(
				page.getByRole("textbox", { name: /description/i }),
			).toHaveValue("Original description");
			await expect(
				page.getByRole("textbox", { name: /location/i }),
			).toHaveValue("Original Location");
			await expect(
				page.getByRole("spinbutton", { name: /maximum capacity/i }),
			).toHaveValue("10");
			await expect(
				page.getByRole("spinbutton", { name: "Member Price", exact: true }),
			).toHaveValue("15");
			await expect(
				page.getByRole("spinbutton", { name: /non-member price/i }),
			).toHaveValue("25");

			// Update details.
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
				.getByRole("spinbutton", { name: "Member Price", exact: true })
				.fill("20");
			await page
				.getByRole("spinbutton", { name: /non-member price/i })
				.fill("30");

			await page.getByRole("button", { name: "Update Workshop" }).click();

			await expect(page.getByText(/updated successfully/i)).toBeVisible();
			await expect(page).toHaveURL("/dashboard/workshops", { timeout: 10000 });
		});

		test("locks editing for a published workshop", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);

			const ts = Date.now();
			const workshop = await createTestWorkshop(page, {
				title: `Published Lock ${ts}`,
				description: "Test description",
				location: "Test Location",
				max_capacity: 10,
				price_member: 1500,
				price_non_member: 2500,
				is_public: true,
				status: "published",
			});
			createdWorkshopIds.push(workshop.id);

			await gotoHydrated(page, `/dashboard/workshops/${workshop.id}/edit`);

			await expect(
				page.getByText(
					/this workshop cannot be edited because it has been published/i,
				),
			).toBeVisible();

			await expect(
				page.getByRole("textbox", { name: /title/i }),
			).toBeDisabled();
			await expect(
				page.getByRole("textbox", { name: /description/i }),
			).toBeDisabled();
			await expect(
				page.getByRole("textbox", { name: /location/i }),
			).toBeDisabled();
			await expect(
				page.getByRole("button", { name: "Update Workshop" }),
			).toBeDisabled();
		});

		test("locks pricing when attendees are registered on a planned workshop", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);

			const ts = Date.now();
			const workshop = await createTestWorkshop(page, {
				title: `Attendees Lock ${ts}`,
				description: "Test description",
				location: "Test Location",
				max_capacity: 10,
				price_member: 1500,
				price_non_member: 2500,
				is_public: false,
				status: "published",
			});
			createdWorkshopIds.push(workshop.id);

			const registration = await createTestRegistration(
				page,
				workshop.id,
				adminData.userId,
			);
			createdRegistrationIds.push(registration.id);

			await gotoHydrated(page, `/dashboard/workshops/${workshop.id}/edit`);

			await expect(
				page.getByText(
					"Pricing cannot be changed because there are already registered attendees.",
				),
			).toBeVisible();
			await expect(
				page.getByRole("spinbutton", { name: /member price/i }),
			).toBeDisabled();
		});

		test("shows validation errors for invalid data", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);

			const ts = Date.now();
			const workshop = await createTestWorkshop(page, {
				title: `Validation Edit ${ts}`,
				description: "Test description",
				location: "Test Location",
				max_capacity: 10,
				price_member: 1500,
				price_non_member: 2500,
				is_public: false,
				status: "planned",
			});
			createdWorkshopIds.push(workshop.id);

			await gotoHydrated(page, `/dashboard/workshops/${workshop.id}/edit`);

			await page.getByRole("textbox", { name: /title/i }).fill("");
			await page.getByRole("textbox", { name: /location/i }).fill("");

			await page.getByRole("button", { name: "Update Workshop" }).click();

			await expect(page.getByText("Title is required")).toBeVisible();
			await expect(page.getByText("Location is required")).toBeVisible();
			await expect
				.poll(() => new URL(page.url()).pathname)
				.toBe(`/dashboard/workshops/${workshop.id}/edit`);
		});

		test("allows workshop_coordinator to edit", async ({ page, context }) => {
			await loginAsUser(context, coordinatorData.email);

			const ts = Date.now();
			const workshopTitle = `Coordinator Edit ${ts}`;
			const workshop = await createTestWorkshop(page, {
				title: workshopTitle,
				description: "Coordinator test",
				location: "Test Location",
				max_capacity: 8,
				price_member: 1200,
				price_non_member: 2000,
				is_public: false,
				status: "planned",
			});
			createdWorkshopIds.push(workshop.id);

			await gotoHydrated(page, `/dashboard/workshops/${workshop.id}/edit`);

			await expect(
				page.getByRole("heading", { name: "Edit Workshop" }),
			).toBeVisible();

			const updatedTitle = `Updated ${workshopTitle}`;
			await page.getByRole("textbox", { name: /title/i }).fill(updatedTitle);
			await page.getByRole("button", { name: "Update Workshop" }).click();

			await expect(page.getByText(/updated successfully/i)).toBeVisible();
		});
	});

	test.describe("modal publish / cancel / delete actions", () => {
		test("publishes a planned workshop", async ({ page, context }) => {
			await loginAsUser(context, adminData.email);

			const ts = Date.now();
			const title = `Publish Test ${ts}`;
			const start = dayjs().add(1, "day").hour(14).minute(0);
			const workshop = await createWorkshop({
				title,
				description: "Test workshop for publishing",
				location: "Test Location",
				start_date: start.toDate(),
				end_date: start.add(2, "hour").toDate(),
				max_capacity: 10,
				price_member: 1000,
				price_non_member: 2000,
				is_public: true,
				refund_days: 3,
				created_by: adminData.userId!,
				status: "planned",
			});
			createdWorkshopIds.push(workshop.id);

			await gotoHydrated(page, "/dashboard/workshops");
			const dialog = await openWorkshopModal(page, title);

			await dialog.getByRole("button", { name: "Publish" }).click();

			// Toast confirms the action.
			await expect(
				page.getByText("Workshop published successfully"),
			).toBeVisible({
				timeout: 10000,
			});
		});

		test("cancels a published workshop via popover confirmation", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);

			const ts = Date.now();
			const title = `Cancel Test ${ts}`;
			const start = dayjs().add(1, "day").hour(14).minute(0);
			const workshop = await createWorkshop({
				title,
				description: "Test workshop for cancelling",
				location: "Test Location",
				start_date: start.toDate(),
				end_date: start.add(2, "hour").toDate(),
				max_capacity: 10,
				price_member: 1000,
				price_non_member: 2000,
				is_public: true,
				refund_days: 3,
				created_by: adminData.userId!,
				status: "published",
			});
			createdWorkshopIds.push(workshop.id);

			await gotoHydrated(page, "/dashboard/workshops");
			const dialog = await openWorkshopModal(page, title);

			// The Cancel action opens a popover (not a native dialog) with
			// "Keep Workshop" / "Cancel Workshop" buttons.
			await dialog.getByRole("button", { name: "Cancel" }).click();
			await expect(
				page.getByRole("button", { name: "Cancel Workshop" }),
			).toBeVisible();
			await page.getByRole("button", { name: "Cancel Workshop" }).click();

			await expect(
				page.getByText("Workshop cancelled successfully"),
			).toBeVisible({
				timeout: 10000,
			});
		});

		test("deletes a planned workshop via popover confirmation", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);

			const ts = Date.now();
			const title = `Delete Test ${ts}`;
			const start = dayjs().add(1, "day").hour(14).minute(0);
			const workshop = await createWorkshop({
				title,
				description: "Test workshop for deleting",
				location: "Test Location",
				start_date: start.toDate(),
				end_date: start.add(2, "hour").toDate(),
				max_capacity: 10,
				price_member: 1000,
				price_non_member: 2000,
				is_public: true,
				refund_days: 3,
				created_by: adminData.userId!,
				status: "planned",
			});
			createdWorkshopIds.push(workshop.id);

			await gotoHydrated(page, "/dashboard/workshops");
			const dialog = await openWorkshopModal(page, title);

			await dialog.getByRole("button", { name: "Delete" }).click();
			await expect(
				page.getByRole("button", { name: "Delete Workshop" }),
			).toBeVisible();
			await page.getByRole("button", { name: "Delete Workshop" }).click();

			await expect(page.getByText("Workshop deleted successfully")).toBeVisible(
				{
					timeout: 10000,
				},
			);
			// Workshop disappears from the calendar.
			await expect(page.getByRole("button", { name: title })).not.toBeVisible({
				timeout: 10000,
			});

			// Remove from cleanup list since it's already deleted.
			const idx = createdWorkshopIds.indexOf(workshop.id);
			if (idx >= 0) createdWorkshopIds.splice(idx, 1);
		});
	});

	test.describe("attendee management", () => {
		let workshopId: string;

		test.beforeAll(async () => {
			// One published workshop shared across attendee tests, with three
			// registrations so the list is non-empty.
			const ts = Date.now();
			const start = dayjs().add(7, "day").hour(14).minute(0);
			const workshop = await createWorkshop({
				title: `Attendee Workshop ${ts}`,
				description: "Attendee management fixture",
				location: "Test Location",
				start_date: start.toDate(),
				end_date: start.add(2, "hour").toDate(),
				max_capacity: 10,
				price_member: 2500,
				price_non_member: 3500,
				is_public: true,
				refund_days: 3,
				created_by: adminData.userId!,
				status: "published",
			});
			workshopId = workshop.id;
			createdWorkshopIds.push(workshopId);

			const regAttrs: E2ERegistrationSeedRequest[] = [
				adminData.userId,
				memberData.userId,
				coordinatorData.userId,
			].map((userId) => ({
				workshopId,
				memberUserId: userId,
				amountPaid: 2500,
				status: "confirmed" as const,
				currency: "EUR",
			}));
			for (const attrs of regAttrs) {
				const reg = await seedE2EScenario("registration", attrs);
				createdRegistrationIds.push(reg.id);
			}
		});

		test("displays the attendee management page", async ({ page, context }) => {
			await loginAsUser(context, adminData.email);
			await gotoHydrated(page, `/dashboard/workshops/${workshopId}/attendees`);

			await expect(
				page.getByRole("heading", { name: "Workshop Attendees" }),
			).toBeVisible();
			await expect(
				page.getByText("Manage attendance and process refunds"),
			).toBeVisible();
			await expect(page.getByText("Registered Attendees")).toBeVisible();
			await expect(page.getByText("Refund").first()).toBeVisible();
		});

		test("lists attendees with attendance status badges", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);
			await gotoHydrated(page, `/dashboard/workshops/${workshopId}/attendees`);

			// Default attendance status renders as "Not Checked In" (human label,
			// not the raw "pending" enum).
			await expect(page.getByText("Not Checked In").first()).toBeVisible({
				timeout: 10000,
			});
		});

		test("marks an attendee as checked in", async ({ page, context }) => {
			await loginAsUser(context, adminData.email);
			await gotoHydrated(page, `/dashboard/workshops/${workshopId}/attendees`);

			// The per-row "Mark Checked In" button updates attendance to "attended".
			// "Mark Checked In" appears both as a bulk action (disabled until rows are
			// selected) and per-row; the first enabled per-row button is the target.
			const checkInButtons = page.getByRole("button", {
				name: "Mark Checked In",
			});
			await expect(checkInButtons.first()).toBeVisible({ timeout: 10000 });

			// Click the first enabled one (the per-row buttons; the bulk one is
			// disabled without a selection).
			const perRowButton = checkInButtons.nth(1);
			await perRowButton.click();

			// The attendance badge flips from "Not Checked In" to "Checked In".
			await expect(page.getByText("Checked In").first()).toBeVisible({
				timeout: 10000,
			});
		});

		test("opens the refund popover and processes a refund", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);
			await gotoHydrated(page, `/dashboard/workshops/${workshopId}/attendees`);
			await page.waitForLoadState("networkidle");

			// The refund UI is a popover triggered by the first refundable attendee.
			const refundButton = page.getByRole("button", { name: "Refund" }).first();
			await expect(refundButton).toBeVisible({ timeout: 10000 });
			await refundButton.click();

			await expect(page.getByText("Confirm Refund")).toBeVisible({
				timeout: 10000,
			});

			const popover = page
				.locator('[data-slot="popover-content"]')
				.filter({ hasText: "Confirm Refund" });
			await popover.getByRole("button", { name: "Confirm" }).click();

			await expect(page.getByText("Refund processed")).toBeVisible({
				timeout: 10000,
			});
		});

		test("closes the refund popover on cancel", async ({ page, context }) => {
			await loginAsUser(context, adminData.email);
			await gotoHydrated(page, `/dashboard/workshops/${workshopId}/attendees`);
			await page.waitForLoadState("networkidle");

			const refundButton = page.getByRole("button", { name: "Refund" }).first();
			await expect(refundButton).toBeVisible({ timeout: 10000 });
			await refundButton.click();

			await expect(page.getByText("Confirm Refund")).toBeVisible({
				timeout: 10000,
			});
			const popover = page
				.locator('[data-slot="popover-content"]')
				.filter({ hasText: "Confirm Refund" });
			await popover.getByRole("button", { name: "Cancel" }).click();

			// Popover closes; the heading is gone.
			await expect(page.getByText("Confirm Refund")).not.toBeVisible();
		});

		test("returns 404 for a non-existent workshop", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);
			const response = await gotoHydrated(
				page,
				`/dashboard/workshops/${NON_EXISTENT_WORKSHOP_ID}/attendees`,
			);

			expect(response?.status()).toBe(404);
			await expect(
				page
					.getByText("404")
					.or(page.getByText("Not Found"))
					.or(page.getByText("Workshop not found")),
			).toBeVisible({ timeout: 5000 });
		});

		test("redirects members without a workshop role", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, memberData.email);
			await gotoHydrated(page, `/dashboard/workshops/${workshopId}/attendees`);

			expect(page.url()).toContain("/dashboard/members");
		});
	});
});
