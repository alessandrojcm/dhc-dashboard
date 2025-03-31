import { expect, test } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Settings Management - Admin', () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		adminData = await createMember({ email: 'admin@test.com', roles: new Set(['admin']) });
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, 'admin@test.com');
	});
	test.afterAll(() => adminData?.cleanUp());

	test('should be able to update settings', async ({ page }) => {
		await page.goto('/dashboard/members');
		await page.getByRole('button', { name: /settings/i }).click();
		await page.getByLabel(/hema insurance form link/i).fill('https://example.com/insurance');
		await page.getByRole('button', { name: /save settings/i }).click();
		await expect(page.getByText(/settings updated successfully/i)).toBeVisible();
	});

	test('should be able to toggle waitlist', async ({ page }) => {
		await page.goto('/dashboard/beginners-workshop');
		const toggleButton = page.getByText(/open waitlist|close waitlist/i);
		await expect(toggleButton).toBeVisible();

		// Click the toggle button
		await toggleButton.click();

		// Confirm the action in the alert dialog
		await page.getByTestId('action').click();

		// Check for success message
		await expect(page.getByText(/waitlist status updated/i)).toBeVisible();
	});
});

test.describe('Settings Management - Committee Coordinator', () => {
	let coordinatorData: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		coordinatorData = await createMember({
			email: 'coordinator@test.com',
			roles: new Set(['committee_coordinator'])
		});
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, 'coordinator@test.com');
	});
	test.afterAll(() => coordinatorData?.cleanUp());

	test('should be able to update settings', async ({ page }) => {
		await page.goto('/dashboard/members');
		await page.getByRole('button', { name: /settings/i }).click();
		await page.getByLabel(/hema insurance form link/i).fill('https://example.com/insurance');
		await page.getByRole('button', { name: /save settings/i }).click();
		await expect(page.getByText(/settings updated successfully/i)).toBeVisible();
	});

	test('should be able to toggle waitlist', async ({ page }) => {
		await page.goto('/dashboard/beginners-workshop');
		const toggleButton = page.getByText(/open waitlist|close waitlist/i);
		await expect(toggleButton).toBeVisible();

		// Click the toggle button
		await toggleButton.click();

		// Confirm the action in the alert dialog
		await page.getByTestId('action').click();

		// Check for success message
		await expect(page.getByText(/waitlist status updated/i)).toBeVisible();
	});
});

test.describe('Settings Management - President', () => {
	let presidentData: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		presidentData = await createMember({
			email: 'president@test.com',
			roles: new Set(['president'])
		});
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, 'president@test.com');
	});
	test.afterAll(() => presidentData?.cleanUp());

	test('should be able to update settings', async ({ page }) => {
		await page.goto('/dashboard/members');
		await page.getByRole('button', { name: /settings/i }).click();
		await page.getByLabel(/hema insurance form link/i).fill('https://example.com/insurance');
		await page.getByRole('button', { name: /save settings/i }).click();
		await expect(page.getByText(/settings updated successfully/i)).toBeVisible();
	});

	test('should be able to toggle waitlist', async ({ page }) => {
		await page.goto('/dashboard/beginners-workshop');
		const toggleButton = page.getByText(/open waitlist|close waitlist/i);
		await expect(toggleButton).toBeVisible();

		// Click the toggle button
		await toggleButton.click();

		// Confirm the action in the alert dialog
		await page.getByTestId('action').click();

		// Check for success message
		await expect(page.getByText(/waitlist status updated/i)).toBeVisible();
	});
});

test.describe('Settings Management - Quartermaster', () => {
	let quartermasterData: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		quartermasterData = await createMember({
			email: 'quartermaster@test.com',
			roles: new Set(['quartermaster', 'member'])
		});
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, 'quartermaster@test.com');
	});
	test.afterAll(() => quartermasterData?.cleanUp());

	test('should not see settings button', async ({ page }) => {
		await page.goto('/dashboard/members');
		await expect(page.getByRole('button', { name: /settings/i })).not.toBeVisible();
	});

	test('should not see waitlist toggle', async ({ page }) => {
		await page.goto('/dashboard/beginners-workshop');
		const toggleButton = page.getByText(/open waitlist|close waitlist/i);
		await expect(toggleButton).not.toBeVisible();
	});
});

test.describe('Settings Management - Regular Member', () => {
	let memberData: Awaited<ReturnType<typeof createMember>>;
	test.beforeAll(async () => {
		memberData = await createMember({
			email: `member-${Date.now()}@test.com`,
			roles: new Set(['member'])
		});
	});
	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, memberData.email);
	});
	test.afterAll(() => memberData?.cleanUp());

	test('should not see settings button', async ({ page }) => {
		await page.goto('/dashboard/members');
		await expect(page.getByRole('button', { name: /settings/i })).not.toBeVisible();
	});

	test('should not see waitlist toggle', async ({ page }) => {
		await page.goto('/dashboard/beginners-workshop');
		expect(page.getByText(/open waitlist|close waitlist/i)).not.toBeVisible();
	});
});
