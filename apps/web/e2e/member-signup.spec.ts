import { expect, test, type Page } from "@playwright/test";
import "dotenv/config";
import { setupInvitedUser } from "./setupFunctions";

function getStripeFrame(page: Page) {
	return page.locator(".__PrivateStripeElement").frameLocator("iframe");
}

test.describe("Member Signup - Negative test cases", () => {
	test("shows an error for a missing invitation", async ({ page }) => {
		await page.goto("/members/signup/00000000-0000-0000-0000-000000000000");

		await expect(page.getByRole("alert")).toContainText("Invitation not found");
	});

	test("rejects details that do not match the invitation", async ({ page }) => {
		const invitation = await setupInvitedUser();

		try {
			await page.goto(
				`/members/signup/${invitation.invitationId}?email=wrong%40example.com&dateOfBirth=${invitation.date_of_birth.format("YYYY-MM-DD")}`,
			);
			await page.waitForLoadState("networkidle");
			await page.getByRole("button", { name: /verify invitation/i }).click();

			await expect(page.getByRole("alert")).toContainText(
				"Something has gone wrong",
			);
		} finally {
			await invitation.cleanUp();
		}
	});

	test("rejects an expired invitation", async ({ page }) => {
		const invitation = await setupInvitedUser({ invitationStatus: "expired" });

		try {
			await page.goto(
				`/members/signup/${invitation.invitationId}?email=${encodeURIComponent(invitation.email)}&dateOfBirth=${invitation.date_of_birth.format("YYYY-MM-DD")}`,
			);
			await page.waitForLoadState("networkidle");
			await page.getByRole("button", { name: /verify invitation/i }).click();

			await expect(page.getByRole("alert")).toContainText(
				"Something has gone wrong",
			);
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
		await page.goto(
			`/members/signup/${invitation.invitationId}?email=${encodeURIComponent(invitation.email)}&dateOfBirth=${invitation.date_of_birth.format("YYYY-MM-DD")}`,
		);
		await page.getByRole("button", { name: /verify invitation/i }).click();

		await expect(page.getByLabel("Next of Kin", { exact: true })).toBeVisible();
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
		// Start from the signup page with invitationId in the URL
		await page.goto(
			`/members/signup/${testData.invitationId}?email=${encodeURIComponent(
				testData.email,
			)}&dateOfBirth=${encodeURIComponent(
				testData.date_of_birth.format("YYYY-MM-DD"),
			)}`,
		);
		await page.waitForLoadState("networkidle");
		await page.getByText(/verify invitation/i).click();

		// Wait for verification to complete and payment form to be visible
		await expect(page.getByLabel("Next of Kin", { exact: true })).toBeVisible();
		await expect(page.locator("#payment-element-state")).toHaveAttribute(
			"data-ready",
			"true",
		);
		await expect(getStripeFrame(page).getByLabel("IBAN")).toBeVisible({
			timeout: 15_000,
		});
	});

	test.afterEach(async () => {
		await testData.cleanUp();
	});

	test("Closed page without completing payment", async ({ page }) => {
		await page.goto("/dashboard/members");
	});

	test("should show all required form steps", async ({ page }) => {
		await expect(page.getByLabel("Next of Kin", { exact: true })).toBeVisible();
		await expect(page.getByLabel("Next of Kin Phone Number")).toBeVisible();
		await expect(page.getByText("Payment details")).toBeVisible();
		await expect(page.locator("#payment-element iframe").first()).toBeVisible();
		await expect(page.getByRole("button", { name: /sign up/i })).toBeVisible();
	});

	test("should validate required fields", async ({ page }) => {
		// Try to proceed without filling required fields
		await page.getByRole("button", { name: "Sign Up" }).click();
		// Check for validation messages
		await expect(
			page.getByPlaceholder(/full name of your next of kin/i),
		).toBeVisible();
		await expect(
			page.getByPlaceholder(/enter your next of kin's phone number/i),
		).toBeVisible();
	});

	test("should format phone numbers correctly", async ({ page }) => {
		// Test phone number formatting for both fields
		const raw_phone_number = "0838774532";
		// The new phone input component formats differently - it removes the leading 0
		const expected_format = "083 877 4532";

		// Find the phone input field (it's now inside the phone input component)
		// The new component has a div wrapper with an Input of type tel inside
		const phoneInputField = page.getByLabel("Next of Kin Phone Number");

		await phoneInputField.pressSequentially(raw_phone_number, {
			delay: 50,
		});
		await phoneInputField.press("Tab");
		await expect(phoneInputField).toHaveValue(expected_format);
	});

	test("should set up the member and process payment", async ({ page }) => {
		// Fill in the form
		await page.getByLabel("Next of Kin", { exact: true }).fill("John Doe");

		// Find the phone input field (it's now inside the phone input component)
		// The new component has a div wrapper with an Input of type tel inside
		const phoneInputField = page.getByLabel("Next of Kin Phone Number");

		await phoneInputField.pressSequentially("0838774532", { delay: 50 });
		await phoneInputField.press("Tab");
		const stripeFrame = getStripeFrame(page);
		// Stripe's succesful IBAN number
		await stripeFrame.getByLabel("IBAN").fill("IE29AIBK93115212345678");
		await stripeFrame.getByLabel("Email").fill(testData.email);
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
		await page.getByRole("button", { name: /sign up/i }).click();
		await expect(
			page.getByText(
				"Your membership has been successfully processed. Welcome to Dublin Hema Club! You will receive a Discord invite by email shortly.",
			),
		).toBeVisible({ timeout: 30000 });
	});

	test("should show error when payment exceeds weekly limit", async ({
		page,
	}) => {
		// Fill in the form
		await page.getByLabel("Next of Kin", { exact: true }).fill("John Doe");

		// Find the phone input field (it's now inside the phone input component)
		// The new component has a div wrapper with an Input of type tel inside
		const phoneInputField = page.getByLabel("Next of Kin Phone Number");

		await phoneInputField.pressSequentially("0838774532", { delay: 50 });
		await phoneInputField.press("Tab");

		const stripeFrame = getStripeFrame(page);
		// Stripe IBAN that triggers weekly limit exceeded error
		await stripeFrame.getByLabel("IBAN").fill("IE69AIBK93115200121212");
		await stripeFrame.getByLabel("Email").fill(testData.email);
		await stripeFrame.getByLabel("Full name").fill("John Doe");
		await stripeFrame.getByLabel("Address line 1").fill("123 Main Street");
		await stripeFrame.getByLabel("Address line 2").fill("Apt 4B");
		await stripeFrame.getByLabel("City").fill("Dublin");
		await stripeFrame.getByLabel("Eircode").fill("K45 HR22");
		await stripeFrame.getByLabel("County").selectOption("Dublin");
		await expect(page.locator("#payment-element-state")).toHaveAttribute(
			"data-complete",
			"true",
		);

		await page.getByRole("button", { name: /sign up/i }).click();
		await expect(page.getByRole("alert")).toContainText(
			"Payment could not be completed",
			{ timeout: 15_000 },
		);
	});

	test("should show error when payment source limit is exceeded", async ({
		page,
	}) => {
		// Fill in the form
		await page.getByLabel("Next of Kin", { exact: true }).fill("John Doe");

		// Find the phone input field (it's now inside the phone input component)
		// The new component has a div wrapper with an Input of type tel inside
		const phoneInputField = page.getByLabel("Next of Kin Phone Number");

		await phoneInputField.pressSequentially("0838774532", { delay: 50 });
		await phoneInputField.press("Tab");

		const stripeFrame = getStripeFrame(page);
		// Stripe IBAN that triggers source limit exceeded error
		await stripeFrame.getByLabel("IBAN").fill("IE10AIBK93115200343434");
		await stripeFrame.getByLabel("Email").fill(testData.email);
		await stripeFrame.getByLabel("Full name").fill("John Doe");
		await stripeFrame.getByLabel("Address line 1").fill("123 Main Street");
		await stripeFrame.getByLabel("Address line 2").fill("Apt 4B");
		await stripeFrame.getByLabel("City").fill("Dublin");
		await stripeFrame.getByLabel("Eircode").fill("K45 HR22");
		await stripeFrame.getByLabel("County").selectOption("Dublin");
		await expect(page.locator("#payment-element-state")).toHaveAttribute(
			"data-complete",
			"true",
		);
		await page.getByRole("button", { name: /sign up/i }).click();
		await expect(page.getByRole("alert")).toContainText(
			"Payment could not be completed",
			{ timeout: 15_000 },
		);
	});
});
