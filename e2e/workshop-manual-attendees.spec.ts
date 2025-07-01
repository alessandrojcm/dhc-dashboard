import { expect, test } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Workshop Manual Attendees', () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let memberData: Awaited<ReturnType<typeof createMember>>;
	let workshopId: string;

	test.beforeAll(async () => {
		const uniqueAdminEmail = `workshop-manual-admin-${Date.now()}@test.com`;
		adminData = await createMember({
			email: uniqueAdminEmail,
			roles: new Set(['admin'])
		});

		const uniqueMemberEmail = `workshop-manual-member-${Date.now()}@test.com`;
		memberData = await createMember({
			email: uniqueMemberEmail,
			roles: new Set(['member'])
		});
	});

	test.beforeEach(async ({ context }) => {
		await loginAsUser(context, adminData.email);
	});

	test.afterAll(() => {
		adminData?.cleanUp();
		memberData?.cleanUp();
	});

	test('should create a workshop and manually add attendees before publishing', async ({ request }) => {
		// Step 1: Create a draft workshop
		const now = new Date();
		const workshopData = {
			workshop_date: now.toISOString(),
			location: 'Test Location for Manual Attendees',
			coach_id: adminData.profileId,
			capacity: 20,
			notes_md: 'Test notes for manual attendees.'
		};

		const createResponse = await request.post('/api/workshops', {
			data: workshopData,
			headers: { 'Content-Type': 'application/json' }
		});

		expect(createResponse.status()).toBe(200);
		const createdWorkshop = await createResponse.json();
		expect(createdWorkshop.status).toBe('draft');
		workshopId = createdWorkshop.id;

		// Step 2: Add a manual attendee
		const addAttendeeResponse = await request.post(`/api/workshops/${workshopId}/attendees`, {
			data: {
				user_profile_id: memberData.profileId,
				priority: 1
			},
			headers: { 'Content-Type': 'application/json' }
		});

		expect(addAttendeeResponse.status()).toBe(200);
		const addedAttendee = await addAttendeeResponse.json();
		expect(addedAttendee.success).toBe(true);

		// Step 3: Verify the attendee was added correctly
		// Note: We can't directly query the database in this test, but we can verify via API responses
		
		// Step 4: Try to add the same attendee again (should fail)
		const duplicateResponse = await request.post(`/api/workshops/${workshopId}/attendees`, {
			data: {
				user_profile_id: memberData.profileId,
				priority: 1
			},
			headers: { 'Content-Type': 'application/json' }
		});

		expect(duplicateResponse.status()).toBe(409); // Conflict - already exists

		// Step 5: Remove the attendee
		const removeResponse = await request.delete(`/api/workshops/${workshopId}/attendees?attendee_id=${addedAttendee.attendee.id}`);
		expect(removeResponse.status()).toBe(200);
	});

	test('should not allow adding attendees to published workshops', async ({ request }) => {
		// Create and publish a workshop
		const now = new Date();
		const workshopData = {
			workshop_date: now.toISOString(),
			location: 'Test Published Workshop',
			coach_id: adminData.profileId,
			capacity: 20,
			notes_md: 'Test published workshop.'
		};

		const createResponse = await request.post('/api/workshops', {
			data: workshopData,
			headers: { 'Content-Type': 'application/json' }
		});

		expect(createResponse.status()).toBe(200);
		const createdWorkshop = await createResponse.json();
		const publishedWorkshopId = createdWorkshop.id;

		// Publish the workshop
		const publishResponse = await request.patch(`/api/workshops/${publishedWorkshopId}/publish`);
		expect(publishResponse.status()).toBe(200);

		// Try to add an attendee to the published workshop (should fail)
		const addAttendeeResponse = await request.post(`/api/workshops/${publishedWorkshopId}/attendees`, {
			data: {
				user_profile_id: memberData.profileId,
				priority: 1
			},
			headers: { 'Content-Type': 'application/json' }
		});

		expect(addAttendeeResponse.status()).toBe(400);
		const error = await addAttendeeResponse.json();
		expect(error.message).toContain('draft workshops');
	});

	test('should require admin permissions', async ({ request, context }) => {
		// Login as regular member (no admin privileges)
		await loginAsUser(context, memberData.email);

		const addAttendeeResponse = await request.post(`/api/workshops/${workshopId}/attendees`, {
			data: {
				user_profile_id: memberData.profileId,
				priority: 1
			},
			headers: { 'Content-Type': 'application/json' }
		});

		expect(addAttendeeResponse.status()).toBe(403);
	});

	test('should handle invalid user profile id', async ({ request }) => {
		const addAttendeeResponse = await request.post(`/api/workshops/${workshopId}/attendees`, {
			data: {
				user_profile_id: '00000000-0000-0000-0000-000000000000', // Non-existent user
				priority: 1
			},
			headers: { 'Content-Type': 'application/json' }
		});

		expect(addAttendeeResponse.status()).toBe(404);
		const error = await addAttendeeResponse.json();
		expect(error.message).toBe('User profile not found');
	});
}); 