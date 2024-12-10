import { test, expect } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';


test.describe('Member Self-Management', () => {
	let testData: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		testData = await createMember({ email: 'test@test.com' });
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, 'test@test.com');
	});
	test.afterAll(() => testData?.cleanUp());

	test('should navigate to member profile whe using only member', async ({ page }) => {
		await page.goto('/dashboard');
		await expect(page.getByText(/member information/i)).toBeVisible();
	});

	test('should update member profile', async ({ page }) => {
		await page.goto('/dashboard');
		await expect(page.getByText(/member information/i)).toBeVisible();
		await page.pause();
		await page.getByLabel(/first name/i).fill('Updated name');
		await page.getByRole('button', { name: /save changes/i }).click();

		await expect(page.getByText(/your profile has been updated/i)).toBeVisible();
		await page.reload();
		await expect(page.getByLabel(/first name/i)).toHaveValue('Updated name');
	});

	test('it should not show other options when user is only member', async ({ page }) => {
		await page.goto('/dashboard');
		expect(page.url()).toContain(`/dashboard/members/${testData.userId}`);
		await expect(page.getByTestId('sidebar')).toHaveText('');
	});
});

test.describe('Member Self-Management - Admin', () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		adminData = await createMember({ email: 'admin@test.com', roles: new Set(['admin']) });
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, 'admin@test.com');
	});
	test.afterAll(() => adminData?.cleanUp());

	test('it should show other options when user is admin', async ({ page }) => {
		await page.goto('/dashboard');
		await page.getByText(adminData.email).click();
		await page.getByText('My profile').click();
		await expect(page.getByTestId('sidebar')).not.toHaveText('');
	});
});
