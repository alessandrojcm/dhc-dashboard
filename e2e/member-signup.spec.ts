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
		await expect(page.getByText('Please enter your next of kin.')).toBeVisible();
		await expect(page.getByText('Phone number of your next of kin is required.')).toBeVisible();
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
});
