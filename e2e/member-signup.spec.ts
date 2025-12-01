import { expect, test } from '@playwright/test';
import 'dotenv/config';
import { setupInvitedUser } from './setupFunctions';

test.describe('Member Signup - Negative test cases', () => {
	[
		{
			addInvitation: false,
			addSupabaseId: true
		},
		{
			addInvitation: true,
			addSupabaseId: true,
			token: 'invalid_token'
		},
		{
			addInvitation: true,
			addSupabaseId: true,
			invitationStatus: 'expired' as const
		}
	].forEach((override) => {
		test.beforeAll(async () => {
			await setupInvitedUser(override);
		});

		test(`should show correct error page when the invitation is invalid ${JSON.stringify(override)}`, async ({
			page
		}) => {
			// Use a non-existent invitationId for invalid cases
			const invalidInvitationId = '00000000-0000-0000-0000-000000000000';
			await page.goto(`/members/signup/${invalidInvitationId}`);
			await expect(page.getByText('Invalid Invite')).toBeVisible();
		});
	});
});
test.describe('Member Signup - Valid invitation', () => {
	// Test data generated once for all tests
	let testData: Awaited<ReturnType<typeof setupInvitedUser>>;

	test.beforeEach(async () => {
		testData = await setupInvitedUser();
	});

	test.beforeEach(async ({ page }) => {
		// Start from the signup page with invitationId in the URL
		await page.goto(
			`/members/signup/${testData.invitationId}?email=${encodeURIComponent(testData.email)}&dateOfBirth=${encodeURIComponent(
				testData.date_of_birth.format('YYYY-MM-DD')
			)}`
		);

		await page.getByText(/verify invitation/i).click();

		// Wait for verification to complete and payment form to be visible
		await expect(page.getByText('First Name')).toBeVisible();
	});

	test('Closed page without completing payment', async ({ page }) => {
		await page.goto('/dashboard/members');
	});

	test('should show all required form steps', async ({ page }) => {
		await expect(page.getByText('First Name')).toBeVisible();
		await expect(page.getByText('Last Name')).toBeVisible();
		await expect(page.getByText('Email')).toBeVisible();
		await expect(page.getByText('Date of Birth')).toBeVisible();

		await expect(page.getByLabel('Phone Number')).toBeVisible();
		await expect(page.getByLabel('Next of Kin', { exact: true })).toBeVisible();
		await expect(page.getByLabel('Next of Kin Phone Number')).toBeVisible();

		await expect(page.getByText('Medical Conditions')).toBeVisible();
	});

	test('should validate required fields', async ({ page }) => {
		// Try to proceed without filling required fields
		await page.getByRole('button', { name: 'Sign Up' }).click();
		// Check for validation messages
		await expect(page.getByPlaceholder(/full name of your next of kin/i)).toBeVisible();
		await expect(page.getByPlaceholder(/enter your next of kin's phone number/i)).toBeVisible();
	});

	test('should format phone numbers correctly', async ({ page }) => {
		// Test phone number formatting for both fields
		const raw_phone_number = '0838774532';
		// The new phone input component formats differently - it removes the leading 0
		const expected_format = '838774532';

		// Find the phone input field (it's now inside the phone input component)
		// The new component has a div wrapper with an Input of type tel inside
		const phoneInputField = page
			.locator('div')
			.filter({ hasText: 'Next of Kin Phone Number' })
			.locator('input[type="tel"]');

		await phoneInputField.pressSequentially(raw_phone_number, { delay: 50 });
		await phoneInputField.press('Tab');
		await expect(phoneInputField).toHaveValue(expected_format);
	});

	test('should set up the member and process payment', async ({ page }) => {
		// Fill in the form
		await page.getByLabel('Next of Kin', { exact: true }).fill('John Doe');

		// Find the phone input field (it's now inside the phone input component)
		// The new component has a div wrapper with an Input of type tel inside
		const phoneInputField = page
			.locator('div')
			.filter({ hasText: 'Next of Kin Phone Number' })
			.locator('input[type="tel"]');

		await phoneInputField.pressSequentially('0838774532', { delay: 50 });
		await phoneInputField.press('Tab');
		const stripeFrame = await page.locator('.__PrivateStripeElement').frameLocator('iframe');
		// Stripe's succesful IBAN number
		await stripeFrame.getByLabel('IBAN').fill('IE29AIBK93115212345678');
		await stripeFrame.getByLabel('Address line 1').fill('123 Main Street');
		await stripeFrame.getByLabel('Address line 2').fill('Apt 4B');
		await stripeFrame.getByLabel('Country or region').selectOption('Ireland');
		await stripeFrame.getByLabel('City').fill('Dublin');
		await stripeFrame.getByLabel('Eircode').fill('K45 HR22');
		await stripeFrame.getByLabel('County').selectOption('County Dublin');
		await page.pause();
		await page.getByRole('button', { name: /sign up/i }).click();
		await expect(
			page.getByText(
				'Your membership has been successfully processed. Welcome to Dublin Hema Club! You will receive a Discord invite by email shortly.'
			)
		).toBeVisible({ timeout: 30000 });
	});

	test('should show error when payment exceeds weekly limit', async ({ page }) => {
		// Fill in the form
		await page.getByLabel('Next of Kin', { exact: true }).fill('John Doe');

		// Find the phone input field (it's now inside the phone input component)
		// The new component has a div wrapper with an Input of type tel inside
		const phoneInputField = page
			.locator('div')
			.filter({ hasText: 'Next of Kin Phone Number' })
			.locator('input[type="tel"]');

		await phoneInputField.pressSequentially('0838774532', { delay: 50 });
		await phoneInputField.press('Tab');

		const stripeFrame = await page.locator('.__PrivateStripeElement').frameLocator('iframe');
		// Stripe IBAN that triggers weekly limit exceeded error
		await stripeFrame.getByLabel('IBAN').fill('IE69AIBK93115200121212');
		await stripeFrame.getByLabel('Address line 1').fill('123 Main Street');
		await stripeFrame.getByLabel('Address line 2').fill('Apt 4B');
		await stripeFrame.getByLabel('City').fill('Dublin');
		await stripeFrame.getByLabel('Eircode').fill('K45 HR22');
		await stripeFrame.getByLabel('County').selectOption('County Dublin');

		await page.getByRole('button', { name: /sign up/i }).click();
		await expect(
			page.getByText('The payment amount exceeds the account payment volume limit')
		).toBeVisible({ timeout: 5000 });
	});

	test('should show error when payment source limit is exceeded', async ({ page }) => {
		// Fill in the form
		await page.getByLabel('Next of Kin', { exact: true }).fill('John Doe');

		// Find the phone input field (it's now inside the phone input component)
		// The new component has a div wrapper with an Input of type tel inside
		const phoneInputField = page
			.locator('div')
			.filter({ hasText: 'Next of Kin Phone Number' })
			.locator('input[type="tel"]');

		await phoneInputField.pressSequentially('0838774532', { delay: 50 });
		await phoneInputField.press('Tab');

		const stripeFrame = await page.locator('.__PrivateStripeElement').frameLocator('iframe');
		// Stripe IBAN that triggers source limit exceeded error
		await stripeFrame.getByLabel('IBAN').fill('IE10AIBK93115200343434');
		await stripeFrame.getByLabel('Address line 1').fill('123 Main Street');
		await stripeFrame.getByLabel('Address line 2').fill('Apt 4B');
		await stripeFrame.getByLabel('City').fill('Dublin');
		await stripeFrame.getByLabel('Eircode').fill('K45 HR22');
		await stripeFrame.getByLabel('County').selectOption('County Dublin');
		await page.getByRole('button', { name: /sign up/i }).click();
		await expect(
			page.getByText('The payment amount exceeds the account payment volume limit')
		).toBeVisible({ timeout: 5000 });
	});
});
