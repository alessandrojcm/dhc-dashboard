import { faker } from "@faker-js/faker";
import { expect, type Page, test } from "@playwright/test";
import dayjs, { type Dayjs } from "dayjs";
import { loginAsUser } from "./auth";
import { deleteE2EFixture, seedE2EScenario } from "./e2eApi";
import { gotoHydrated } from "./hydration";
import { createMember } from "./setupFunctions";

const successMessage =
	"You have been added to the waitlist, we will be in contact soon!";

async function openWaitlist(page: Page) {
	await page.goto("/waitlist");
	await page.waitForLoadState("networkidle");
}

async function selectDateOfBirth(page: Page, dateOfBirth: Dayjs) {
	const trigger = page.getByLabel("Date of birth");
	await trigger.scrollIntoViewIfNeeded();
	await expect(trigger).toBeVisible();
	await trigger.click();
	await page
		.getByLabel("Select a year")
		.selectOption(dateOfBirth.year().toString());
	await page.getByLabel("Select a month").selectOption(dateOfBirth.format("M"));
	await page
		.getByRole("button", { name: dateOfBirth.format("dddd, MMMM D,") })
		.click();
}

async function fillWaitlistForm(page: Page, dateOfBirth: Dayjs) {
	await page.getByLabel("First name").fill(faker.person.firstName());
	await page.getByLabel("Last name").fill(faker.person.lastName());
	await page
		.getByLabel("Email")
		.fill(`waitlist-${Date.now()}-${faker.string.alphanumeric(6)}@test.com`);
	await page.getByLabel("Phone number").fill("0840997863");
	await page.getByRole("button", { name: "Gender", exact: true }).click();
	await page.getByRole("option", { name: "man (cis)", exact: true }).click();
	await page.getByLabel("Pronouns").fill("he/him");
	await selectDateOfBirth(page, dateOfBirth);
	await page.getByRole("radio", { name: "No", exact: true }).click();
	await page.getByLabel("Any medical condition?").fill("None");
}

test.describe("Beginners waitlist", () => {
	test.beforeEach(async () => {
		await seedE2EScenario("waitlistStatus", { isOpen: true });
	});
	test.afterAll(async () => {
		await seedE2EScenario("waitlistStatus", { isOpen: true });
	});

	test("adult can join without guardian information", async ({ page }) => {
		await openWaitlist(page);
		await fillWaitlistForm(page, dayjs().subtract(25, "years"));

		await expect(
			page.getByText("Guardian Information (Required for under 18)"),
		).not.toBeVisible();
		await page.getByRole("button", { name: "Submit" }).click();
		await expect(page.getByText(successMessage)).toBeVisible();
	});

	test("person under 16 cannot join", async ({ page }) => {
		await openWaitlist(page);
		await selectDateOfBirth(page, dayjs().subtract(15, "years"));
		await page.getByRole("button", { name: "Submit" }).click();

		await expect(
			page.getByText(/you must be at least 16 years old/i),
		).toBeVisible();
	});

	test("closed waitlist hides the form", async ({ page }) => {
		await seedE2EScenario("waitlistStatus", { isOpen: false });
		await openWaitlist(page);

		await expect(
			page.getByText(/the waitlist is currently closed/i),
		).toBeVisible();
	});

	test("underage person sees required guardian fields", async ({ page }) => {
		await openWaitlist(page);
		await fillWaitlistForm(page, dayjs().subtract(17, "years"));

		await expect(
			page.getByText("Guardian Information (Required for under 18)"),
		).toBeVisible();
		await page.getByRole("button", { name: "Submit" }).click();
		await expect(
			page.getByText("Guardian first name is required"),
		).toBeVisible();
		await expect(
			page.getByText("Guardian last name is required"),
		).toBeVisible();
		await expect(
			page.getByText("Guardian phone number is required"),
		).toBeVisible();
	});

	test("underage person can join with guardian information", async ({
		page,
	}) => {
		await openWaitlist(page);
		await fillWaitlistForm(page, dayjs().subtract(17, "years"));
		await page.getByLabel("Guardian First Name").fill(faker.person.firstName());
		await page.getByLabel("Guardian Last Name").fill(faker.person.lastName());
		await page.getByLabel("Guardian Phone Number").fill("0840998877");
		await page.getByRole("button", { name: "Submit" }).click();

		await expect(page.getByText(successMessage)).toBeVisible();
	});
});

test.describe("Beginners waitlist view", () => {
	const waitlistPath = "/dashboard/beginners-workshop?tab=waitlist";
	const suffix = `${Date.now()}-${faker.string.alphanumeric(6)}`;
	const waitingName = `QueueWaiting${faker.string.alpha(6)}`;
	const removedName = `QueueRemoved${faker.string.alpha(6)}`;
	const attendedName = `QueueAttended${faker.string.alpha(6)}`;
	const waitlistIds: string[] = [];
	let coordinator: Awaited<ReturnType<typeof createMember>>;
	let coach: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		coordinator = await createMember({
			email: `beginners-coordinator-${suffix}@test.com`,
			roles: new Set(["beginners_coordinator"]),
		});
		coach = await createMember({
			email: `beginners-coach-${suffix}@test.com`,
			roles: new Set(["coach"]),
		});

		for (const [firstName, status] of [
			[waitingName, "waiting"],
			[removedName, "removed"],
			[attendedName, "attended"],
		] as const) {
			const seeded = await seedE2EScenario("waitlist", {
				firstName,
				lastName: "Queue",
				email: `${firstName.toLowerCase()}-${suffix}@example.com`,
				status,
			});
			waitlistIds.push(seeded.waitlistId);
		}
	});

	test.afterAll(async () => {
		for (const id of waitlistIds) await deleteE2EFixture("waitlist", id);
		await coordinator?.cleanUp();
		await coach?.cleanUp();
	});

	test("lists waiting people by default, with removed people behind a filter", async ({
		context,
		page,
	}) => {
		await page.setViewportSize({ width: 1280, height: 720 });
		await loginAsUser(context, coordinator.email);
		await gotoHydrated(page, waitlistPath);

		const table = page
			.getByRole("tabpanel", { name: "Waitlist" })
			.getByRole("table");
		await expect(table.getByText(`${waitingName} Queue`)).toBeVisible();
		await expect(table.getByText(`${removedName} Queue`)).toHaveCount(0);
		await expect(table.getByText(`${attendedName} Queue`)).toHaveCount(0);

		// Status is read-only and nobody is invited from the Waitlist view.
		await expect(page.getByRole("button", { name: /invite/i })).toHaveCount(0);

		await page.getByRole("radio", { name: "Removed" }).click();
		await expect(page).toHaveURL(/status=removed/);
		await expect(table.getByText(`${removedName} Queue`)).toBeVisible();
		await expect(table.getByText(`${waitingName} Queue`)).toHaveCount(0);
		await expect(
			table.getByText(/^Removed \d{2}\/\d{2}\/\d{4}$/),
		).toBeVisible();

		await page.getByRole("radio", { name: "Waiting" }).click();
		await expect(page).not.toHaveURL(/status=/);
		await expect(table.getByText(`${waitingName} Queue`)).toBeVisible();
	});

	test("reports the waiting queue as Waiting", async ({ context, page }) => {
		await loginAsUser(context, coordinator.email);
		// Workshop managers land on the Workshops tab (ALE-378), so the
		// Dashboard tab is opened explicitly.
		await gotoHydrated(page, "/dashboard/beginners-workshop?tab=dashboard");

		await expect(
			page
				.getByRole("tabpanel", { name: "Dashboard" })
				.getByText("Waiting", { exact: true }),
		).toBeVisible();
		await expect(page.getByText("Total waitlist")).toHaveCount(0);
	});

	test("coaches no longer see the Waitlist", async ({ context, page }) => {
		await loginAsUser(context, coach.email);
		await gotoHydrated(page, waitlistPath);

		await expect(page).not.toHaveURL(/beginners-workshop/);
		await expect(
			page.getByRole("link", { name: "Beginners Workshop" }),
		).toHaveCount(0);
	});
});
