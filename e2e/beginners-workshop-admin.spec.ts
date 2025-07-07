import { expect, test } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Beginners Workshop Admin Page', () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const uniqueEmail = `workshop-admin-${Date.now()}-${Math.random().toString(36).substring(2, 11)}@test.com`;
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
		await expect(page.getByRole('tab', { name: /workshops/i })).toBeVisible();
		await expect(page.getByText('Create Workshop')).toBeVisible();
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
			headers: {
				'Content-Type': 'application/json',
				cookie: await context
					.cookies()
					.then((cookies) => cookies.map((c) => `${c.name}=${c.value}`).join('; '))
			}
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

		// Clean up: delete the created workshop directly from database to prevent foreign key constraint issues
		// Import supabase client dynamically
		const { getSupabaseServiceClient } = await import('./setupFunctions');
		const client = getSupabaseServiceClient();
		await client.from('workshops').delete().eq('id', created.id);
	});
});
