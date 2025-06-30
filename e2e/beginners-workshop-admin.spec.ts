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

	test('should create a new workshop in draft state via API', async ({ request, context }) => {
		// Login as admin to set the auth cookie
		await loginAsUser(context, adminData.email);

		// Prepare test data
		const now = new Date();
		const workshopData = {
			workshop_date: now.toISOString(),
			location: 'Test Location',
			coach_id: adminData.profileId, // Use admin's profileId as a valid coach_id for test
			capacity: 20,
			notes_md: 'Test notes for workshop.'
		};

		// Make the API request
		const response = await request.post('/api/workshops', {
			data: workshopData,
			headers: { 'Content-Type': 'application/json' }
		});

		expect(response.status()).toBe(200);
		const created = await response.json();
		expect(created).toMatchObject({
			location: workshopData.location,
			coach_id: workshopData.coach_id,
			capacity: workshopData.capacity,
			notes_md: workshopData.notes_md,
			status: 'draft'
		});
		expect(typeof created.id).toBe('string');
		expect(new Date(created.workshop_date).toISOString()).toBe(workshopData.workshop_date);

		// Clean up: delete the created workshop (if possible)
		// If you have a delete endpoint or direct DB access, add cleanup here
	});
}); 