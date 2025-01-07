import { test, expect } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';
// TODO: update stripe details when settings are updated (only phone & name)

test.describe('Member Self-Management', () => {
	let testData: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		testData = await createMember({ email: 'test@test.com', createSubscription: true });
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
		await page.getByLabel(/preferred weapon/i).click();
		await page.getByRole('option', { name: 'Longsword' }).click();
		await page.getByRole('button', { name: /save changes/i }).click();

		await expect(page.getByText(/profile has been updated/i)).toBeVisible();
		await page.reload();
		await expect(page.getByLabel(/first name/i)).toHaveValue('Updated name');
	});

	test('it should show manage subscription button', async ({ page }) => {
		await page.goto('/dashboard');
		await page.getByText(/manage payment settings/i).click();
		await expect(page).toHaveURL(/billing\.stripe\.com/);
	});

	test('it should not show other options when user is only member', async ({ page }) => {
		await page.goto('/dashboard');
		expect(page.url()).toContain(`/dashboard/members/${testData.userId}`);
		await expect(page.getByTestId('sidebar')).toHaveText('');
	});
});

test.describe('Member Management - Admin', () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let memberData: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		adminData = await createMember({ email: 'admin@test.com', roles: new Set(['admin']) });
		memberData = await createMember({ email: 'member@test.com', roles: new Set(['member']) });
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, 'admin@test.com');
	});
	test.afterAll(() => Promise.all([adminData?.cleanUp(), memberData?.cleanUp()]));

	test('it should show other options when user is admin', async ({ page }) => {
		await page.goto('/dashboard');
		await page.getByText(adminData.email).click();
		await page.getByText('My profile').click();
		await expect(page.getByTestId('sidebar')).not.toHaveText('');
	});

	test('admin should be able to navigate to a specific member profile', async ({ page }) => {
		await page.goto(`/dashboard/members/${memberData.userId}`);
		await page.getByLabel(/first name/i).fill('Updated name');
		await page.getByRole('button', { name: /save changes/i }).click();
		await expect(page.getByText(/profile has been updated/i)).toBeVisible();
		await page.reload();
		await expect(page.getByLabel(/first name/i)).toHaveValue('Updated name');
	});
});

test.describe('Member management - cross member role check', () => {
	let memberOne: Awaited<ReturnType<typeof createMember>>;
	let memberTwo: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		memberOne = await createMember({ email: 'member1@member.com', roles: new Set(['member']) });
		memberTwo = await createMember({ email: 'member2@member.com', roles: new Set(['member']) });
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, 'member1@member.com');
	});
	test.afterAll(() => Promise.all([memberOne?.cleanUp(), memberTwo?.cleanUp()]));

	test("it should not allow to navigate to another member's profile", async ({ page }) => {
		const response = await page.goto(`/dashboard/members/${memberTwo.userId}`);
		expect(response?.status()).toBe(404);
		await expect(page.getByText(/member not found/i)).toBeVisible();
	});
});
