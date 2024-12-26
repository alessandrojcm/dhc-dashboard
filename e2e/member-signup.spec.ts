import { test, expect } from '@playwright/test';
import 'dotenv/config';
import { setupWaitlistedUser } from './setupFunctions';

test.describe('Member Signup - Negative test cases', () => {
	[
		{
			addWaitlist: false,
			addSupabaseId: true
		},
		{
			addWaitlist: true,
			addSupabaseId: false
		},
		{
			addWaitlist: true,
			addSupabaseId: true,
			token: 'invalid_token'
		},
		{
			addWaitlist: true,
			addSupabaseId: true,
			setWaitlistNotCompleted: true
		}
	].forEach((override) => {
		let testData: Awaited<ReturnType<typeof setupWaitlistedUser>>;
		test.beforeAll(async () => {
			testData = await setupWaitlistedUser(override);
		});

		test(`should show correct error page when the waitlist entry is wrong ${JSON.stringify(override)}`, async ({
			page
		}) => {
			await page.goto(
				'/members/signup?access_token=' +
					(override?.token !== undefined ? override.token : testData.token)
			);
			await expect(page.getByText('Something has gone wrong')).toBeVisible();
		});
	});
});
test.describe('Member Signup - Correct token', () => {
	// Test data generated once for all tests
	let testData: Awaited<ReturnType<typeof setupWaitlistedUser>>;

	test.beforeEach(async () => {
		testData = await setupWaitlistedUser();
	});

	test.beforeEach(async ({ page }) => {
		// Start from the signup page
		await page.goto('/members/signup?access_token=' + testData.token);
		// Wait for the form to be visible
		await page.waitForSelector('form');
	});

	test('should show all required form steps', async ({ page }) => {
		await expect(page.getByText(/join dublin hema club/i)).toBeVisible();
		await expect(page.getByText('First Name')).toBeVisible();
		await expect(page.getByText('Last Name')).toBeVisible();
		await expect(page.getByText('Email')).toBeVisible();
		await expect(page.getByText('Date of Birth')).toBeVisible();

		await expect(page.getByLabel('Phone Number')).toBeVisible();
		await expect(page.getByLabel('Next of Kin', { exact: true })).toBeVisible();
		await expect(page.getByLabel('Next of Kin Phone Number')).toBeVisible();

		await expect(page.getByText('Medical Conditions')).toBeVisible();
		await expect(page.getByLabel(/insurance form/)).toBeVisible();
	});

	test('should validate required fields', async ({ page }) => {
		// Try to proceed without filling required fields
		await page.getByRole('button', { name: 'Complete Sign Up' }).click();
		// Check for validation messages
		await expect(page.getByPlaceholder(/full name of your next of kin/i)).toBeVisible();
		await expect(page.getByPlaceholder(/enter your next of kin's phone number/i)).toBeVisible();
	});

	test('should format phone numbers correctly', async ({ page }) => {
		// Test phone number formatting for both fields
		const raw_phone_number = '0838774532';
		const expected_format = '083 877 4532';

		await page
			.getByLabel('Next of Kin Phone Number')
			.pressSequentially(raw_phone_number, { delay: 50 });
		await page.locator('input[name="nextOfKinNumber"]').press('Tab');
		await expect(page.getByLabel('Next of Kin Phone Number')).toHaveValue(expected_format);
	});

	test('should set up the member and process payment', async ({ page }) => {
		// Fill in the form
		await page.getByLabel('Next of Kin', { exact: true }).fill('John Doe');
		await page
			.getByLabel('Next of Kin Phone Number')
			.pressSequentially('0838774532', { delay: 50 });
		await page.locator('input[name="nextOfKinNumber"]').press('Tab');
		await page
			.getByLabel("Please make sure you have submitted HEMA Ireland's insurance form")
			.check();
		const stripeFrame = await page.locator('.__PrivateStripeElement').frameLocator('iframe');
		// Stripe's succesful IBAN number
		await stripeFrame.getByLabel('IBAN').fill('IE29AIBK93115212345678');
		await stripeFrame.getByLabel('Address line 1').fill('123 Main Street');
		await stripeFrame.getByLabel('Address line 2').fill('Apt 4B');
		await stripeFrame.getByLabel('City').fill('Dublin');
		await stripeFrame.getByLabel('Eircode').fill('K45 HR22');
		await stripeFrame.getByLabel('County').selectOption('County Dublin');
		await page.pause();
		await page.getByRole('button', { name: /sign up/i }).click();
		await expect(page).toHaveURL(/thank-you/, { timeout: 30000 });
	});
});
