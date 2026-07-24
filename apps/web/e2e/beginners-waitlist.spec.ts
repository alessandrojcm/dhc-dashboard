import { faker } from "@faker-js/faker";
import { expect, type Page, test } from "@playwright/test";
import dayjs, { type Dayjs } from "dayjs";
import { seedE2EScenario } from "./e2eApi";

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
