import { expect, test, type Page } from "@playwright/test";
import "dotenv/config";
import {
	routeSuccessfulDiscordAcceptance,
	setupInvitedUser,
} from "./setupFunctions";
import { submitInvitationCredentials } from "./invitationSignup";

type InvitedUser = Awaited<ReturnType<typeof setupInvitedUser>>;

function getStripeFrame(page: Page) {
	return page.locator(".__PrivateStripeElement").frameLocator("iframe");
}

async function openPaymentForm(page: Page, invitation: InvitedUser) {
	await routeSuccessfulDiscordAcceptance(page, invitation.invitationId);
	await submitInvitationCredentials(page, {
		invitationId: invitation.invitationId,
		email: invitation.email,
		dateOfBirth: invitation.date_of_birth.format("YYYY-MM-DD"),
	});
	await page.getByRole("link", { name: "Continue to Discord" }).click();
	await expect(
		page.getByRole("heading", { name: "Discord verified" }),
	).toBeVisible();
	await page.getByRole("button", { name: "Continue to payment" }).click();
	await expect(page.getByLabel("Next of Kin", { exact: true })).toBeVisible();
	await expect(page.locator("#payment-element-state")).toHaveAttribute(
		"data-ready",
		"true",
	);
	await expect(getStripeFrame(page).getByLabel("IBAN")).toBeVisible({
		timeout: 15_000,
	});
}

async function fillStripePayment(page: Page, email: string, iban: string) {
	const stripeFrame = getStripeFrame(page);
	await stripeFrame.getByLabel("IBAN").fill(iban);
	await stripeFrame.getByLabel("Email").fill(email);
	await stripeFrame.getByLabel("Full name").fill("John Doe");
	await stripeFrame.getByLabel("Address line 1").fill("123 Main Street");
	await stripeFrame.getByLabel("Address line 2").fill("Apt 4B");
	await stripeFrame.getByLabel("Country or region").selectOption("Ireland");
	await stripeFrame.getByLabel("City").fill("Dublin");
	await stripeFrame.getByLabel("Eircode").fill("K45 HR22");
	await stripeFrame.getByLabel("County").selectOption("Dublin");
	await expect(page.locator("#payment-element-state")).toHaveAttribute(
		"data-complete",
		"true",
	);
}

async function expectNeutralInvitationError(page: Page) {
	await expect(
		page.getByRole("alert").filter({ hasText: "Something has gone wrong" }),
	).toBeVisible();
}

test.describe("Member Signup - Negative test cases", () => {
	test("shows a neutral error for a missing invitation", async ({ page }) => {
		await submitInvitationCredentials(page, {
			invitationId: "00000000-0000-0000-0000-000000000000",
			email: "missing-invitation@example.com",
			dateOfBirth: "1990-01-01",
		});

		await expectNeutralInvitationError(page);
	});

	test("rejects details that do not match the invitation", async ({ page }) => {
		const invitation = await setupInvitedUser();

		try {
			await submitInvitationCredentials(page, {
				invitationId: invitation.invitationId,
				email: "wrong@example.com",
				dateOfBirth: invitation.date_of_birth.format("YYYY-MM-DD"),
			});

			await expectNeutralInvitationError(page);
		} finally {
			await invitation.cleanUp();
		}
	});

	test("rejects an expired invitation", async ({ page }) => {
		const invitation = await setupInvitedUser({ invitationStatus: "expired" });

		try {
			await submitInvitationCredentials(page, {
				invitationId: invitation.invitationId,
				email: invitation.email,
				dateOfBirth: invitation.date_of_birth.format("YYYY-MM-DD"),
			});

			await expectNeutralInvitationError(page);
		} finally {
			await invitation.cleanUp();
		}
	});
});

test("verifies an invitation whose birthdate crosses a local timezone boundary", async ({
	page,
}) => {
	const invitation = await setupInvitedUser({
		dateOfBirth: new Date("1985-06-29T23:30:00.000Z"),
	});

	try {
		await submitInvitationCredentials(page, {
			invitationId: invitation.invitationId,
			email: invitation.email,
			dateOfBirth: invitation.date_of_birth.format("YYYY-MM-DD"),
		});

		await expect(
			page.getByRole("heading", { name: "Connect Discord" }),
		).toBeVisible();
	} finally {
		await invitation.cleanUp();
	}
});

test.describe("Member Signup - Valid invitation", () => {
	// Test data generated once for all tests
	let testData: Awaited<ReturnType<typeof setupInvitedUser>>;

	test.beforeEach(async () => {
		testData = await setupInvitedUser();
	});

	test.beforeEach(async ({ page }) => {
		await openPaymentForm(page, testData);
	});

	test.afterEach(async () => {
		await testData.cleanUp();
	});

	test("should validate required fields", async ({ page }) => {
		await fillStripePayment(page, testData.email, "IE29AIBK93115212345678");
		await page.getByRole("button", { name: "Sign Up" }).click();

		await expect(
			page.getByRole("alert").filter({
				hasText: "Please enter your next of kin.",
			}),
		).toBeVisible();
		await expect(
			page.getByRole("alert").filter({
				hasText: "Phone number of your next of kin is required.",
			}),
		).toBeVisible();
	});

	for (const paymentLimit of [
		{
			name: "weekly limit",
			iban: "IE69AIBK93115200121212",
		},
		{
			name: "payment source limit",
			iban: "IE10AIBK93115200343434",
		},
	]) {
		test(`should show an error when ${paymentLimit.name} is exceeded`, async ({
			page,
		}) => {
			await page.getByLabel("Next of Kin", { exact: true }).fill("John Doe");
			const phoneInputField = page.getByLabel("Next of Kin Phone Number");
			await phoneInputField.pressSequentially("0838774532", { delay: 50 });
			await phoneInputField.press("Tab");
			await fillStripePayment(page, testData.email, paymentLimit.iban);

			await page.getByRole("button", { name: /sign up/i }).click();
			await expect(
				page
					.getByText("Payment could not be completed", { exact: true })
					.first(),
			).toBeVisible({ timeout: 15_000 });
			await expect(
				page.getByRole("heading", { name: "Verify Your Invitation" }),
			).toBeVisible();
		});
	}
});
