import { expect, test } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Workshop Publish API', () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let regularMemberData: Awaited<ReturnType<typeof createMember>>;
	let workshopId: string;

	test.beforeAll(async () => {
		const uniqueAdminEmail = `workshop-publish-admin-${Date.now()}@test.com`;
		adminData = await createMember({
			email: uniqueAdminEmail,
			roles: new Set(['admin'])
		});

		const uniqueMemberEmail = `workshop-publish-member-${Date.now()}@test.com`;
		regularMemberData = await createMember({
			email: uniqueMemberEmail,
			roles: new Set(['member'])
		});
	});

	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, adminData.email);
	});

	test.afterAll(() => {
		adminData?.cleanUp();
		regularMemberData?.cleanUp();
	});

	test('should require authentication', async ({ request }) => {
		const response = await request.patch('/api/workshops/fake-id/publish');
		expect(response.status()).toBe(401);
	});

	test('should require proper roles', async ({ request, context }) => {
		// Login as regular member (no admin privileges)
		await loginAsUser(context, regularMemberData.email);

		const response = await request.patch('/api/workshops/fake-id/publish');
		expect(response.status()).toBe(403);
	});

	test('should return 404 for non-existent workshop', async ({ request }) => {
		const response = await request.patch('/api/workshops/00000000-0000-0000-0000-000000000000/publish');
		expect(response.status()).toBe(404);
	});

	test('should create and publish a workshop successfully', async ({ request }) => {
		// First create a draft workshop
		const now = new Date();
		const workshopData = {
			workshop_date: now.toISOString(),
			location: 'Test Location for Publish',
			coach_id: adminData.profileId,
			capacity: 20,
			notes_md: 'Test notes for workshop publish.'
		};

		const createResponse = await request.post('/api/workshops', {
			data: workshopData,
			headers: { 'Content-Type': 'application/json' }
		});

		expect(createResponse.status()).toBe(200);
		const createdWorkshop = await createResponse.json();
		expect(createdWorkshop.status).toBe('draft');
		workshopId = createdWorkshop.id;

		// Now publish the workshop
		const publishResponse = await request.patch(`/api/workshops/${workshopId}/publish`);
		expect(publishResponse.status()).toBe(200);
		
		const publishResult = await publishResponse.json();
		expect(publishResult.success).toBe(true);
		expect(publishResult.workshop.status).toBe('published');
		expect(publishResult.workshop.id).toBe(workshopId);
	});

	test('should not allow publishing already published workshop', async ({ request }) => {
		// Try to publish the same workshop again
		const response = await request.patch(`/api/workshops/${workshopId}/publish`);
		expect(response.status()).toBe(400);
		
		const error = await response.json();
		expect(error.message).toContain('already published');
	});

	test('should handle invalid workshop ID format', async ({ request }) => {
		const response = await request.patch('/api/workshops/invalid-uuid/publish');
		// This might be 404 or 500 depending on how Kysely handles invalid UUIDs
		expect([404, 500]).toContain(response.status());
	});
}); 