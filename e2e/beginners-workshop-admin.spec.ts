import { expect, test } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Beginners Workshop Admin Page', () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const uniqueEmail = `workshop-admin-${Date.now()}@test.com`;
		adminData = await createMember({
			email: uniqueEmail,
			roles: new Set(['admin'])
		});
	});

	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, adminData.email);
	});

	test.afterAll(() => adminData?.cleanUp());

	test('should load the beginners workshop dashboard', async ({ page }) => {
		await page.goto('/dashboard/beginners-workshop');
		await expect(page.getByRole('heading', { name: /workshops/i })).toBeVisible();
		await expect(page.getByRole('button', { name: /create workshop/i })).toBeVisible();
		await expect(page.getByRole('table')).toBeVisible();
	});
}); 