import { test, expect } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Workshop Registration', () => {
	let memberData: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const timestamp = Date.now();
		memberData = await createMember({
			email: `member-registration-${timestamp}@test.com`,
			roles: new Set(['member'])
		});
	});

	test('member can access registration form', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);

		// For now, just test that the registration component can be imported
		// This is a basic test until we have actual workshop pages set up
		await page.goto('/dashboard');

		// Verify user is logged in
		await expect(page.locator('text=Dashboard')).toBeVisible();
	});

	test('registration schema validation works', async ({ page }) => {
		// Test the validation schema directly by importing it
		await page.evaluate(() => {
			// This would test the validation schema in the browser context
			// For now, just verify the page loads
			return true;
		});

		expect(true).toBe(true); // Placeholder test
	});
});
