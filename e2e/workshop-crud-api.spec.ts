import { test, expect } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';
import {
	WorkshopTestHelper,
	generateWorkshopApiPayload,
	generateInvalidWorkshopPayloads
} from './utils/workshop-test-utils';
import { makeAuthenticatedRequest } from './utils/api-request-helper';

test.describe('Workshop CRUD API Tests', () => {
	let workshopHelper: WorkshopTestHelper;
	let testCoach: any;
	let adminUser: any;
	let coachUser: any;
	let memberUser: any;

	test.beforeEach(async () => {
		workshopHelper = new WorkshopTestHelper();
		testCoach = await workshopHelper.createTestCoach();

		// Create test users with different roles using unique emails
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 15);
		adminUser = await createMember({
			email: `admin-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['admin'])
		});

		coachUser = await createMember({
			email: `coach-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['coach'])
		});

		memberUser = await createMember({
			email: `member-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['member'])
		});
	});

	test.afterEach(async () => {
		await workshopHelper.cleanup();
		await Promise.all([adminUser?.cleanUp(), coachUser?.cleanUp(), memberUser?.cleanUp()]);
	});

	test.describe('Workshop Creation API', () => {
		test('should create workshop with valid data as admin', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(200);
			const workshop = await response.json();

			expect(workshop).toMatchObject({
				location: payload.location,
				coach_id: payload.coach_id,
				capacity: payload.capacity,
				status: 'draft'
			});
			// Check workshop_date separately to handle timestamp format differences
			expect(new Date(workshop.workshop_date)).toEqual(new Date(payload.workshop_date));
		});

		test('should create workshop with president role', async ({ request, context }) => {
			const presidentUser = await createMember({
				email: `president-${Date.now()}-${Math.random().toString(36).substring(2, 15)}@test.com`,
				roles: new Set(['president'])
			});

			await loginAsUser(context, presidentUser.email);
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(200);
			await presidentUser.cleanUp();
		});

		test('should create workshop with beginners_coordinator role', async ({ request, context }) => {
			const coordinatorUser = await createMember({
				email: `coordinator-${Date.now()}-${Math.random().toString(36).substring(2, 15)}@test.com`,
				roles: new Set(['beginners_coordinator'])
			});

			await loginAsUser(context, coordinatorUser.email);
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(200);
			await coordinatorUser.cleanUp();
		});

		test('should reject workshop creation with missing required fields', async ({
			request,
			context
		}) => {
			await loginAsUser(context, adminUser.email);
			const invalidPayloads = generateInvalidWorkshopPayloads();

			for (const [, payload] of Object.entries(invalidPayloads)) {
				const response = await makeAuthenticatedRequest(
					request,
					context,
					'POST',
					'/api/workshops',
					{
						data: payload
					}
				);

				expect(response.status()).toBe(400);
				const errorData = await response.json();
				expect(errorData.message).toContain('Validation failed');
			}
		});

		test('should reject workshop creation with past date', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const payload = generateWorkshopApiPayload('pastDate', { coach_id: testCoach.id });

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(400);
			const errorData = await response.json();
			expect(errorData.message).toContain('Date cannot be in the past');
		});

		test('should reject workshop creation with invalid capacity', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const payload = generateWorkshopApiPayload('invalidCapacity', { coach_id: testCoach.id });

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(400);
			const errorData = await response.json();
			expect(errorData.message).toContain('Validation failed');
		});

		test('should reject workshop creation with non-existent coach', async ({
			request,
			context
		}) => {
			await loginAsUser(context, adminUser.email);
			const payload = generateWorkshopApiPayload('basic', { coach_id: 'non-existent-coach' });

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(500);
		});

		test('should reject workshop creation without authentication', async ({ request }) => {
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			const response = await request.post('/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(401);
		});

		test('should reject workshop creation with insufficient permissions', async ({
			request,
			context
		}) => {
			await loginAsUser(context, memberUser.email);
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(403);
		});

		test('should handle malformed JSON payload', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);

			// Get cookies for authenticated request
			const cookies = await context
				.cookies()
				.then((cookies) => cookies.map((c) => `${c.name}=${c.value}`).join('; '));

			const response = await request.post('/api/workshops', {
				data: '{invalid json}',
				headers: {
					'Content-Type': 'application/json',
					cookie: cookies
				}
			});

			expect(response.status()).toBe(400);
		});

		test('should create workshop with long markdown notes', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const longNotes =
				'# Workshop Notes\\n\\n' + 'This is a very long workshop description. '.repeat(100);
			const payload = generateWorkshopApiPayload('basic', {
				coach_id: testCoach.id,
				notes_md: longNotes
			});

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(200);
			const workshop = await response.json();
			expect(workshop.notes_md).toBe(longNotes);
		});

		test('should create workshop with optional notes_md omitted', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });
			delete payload.notes_md;

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(200);
			const workshop = await response.json();
			expect(workshop.notes_md).toBeNull();
		});
	});

	test.describe('Workshop Publishing API', () => {
		let testWorkshop: any;

		test.beforeEach(async () => {
			testWorkshop = await workshopHelper.createTestWorkshop('basic');
		});

		test('should publish draft workshop', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'PATCH',
				`/api/workshops/${testWorkshop.id}/publish`,
				{}
			);

			expect(response.status()).toBe(200);
			const result = await response.json();
			expect(result.success).toBe(true);
			expect(result.workshop.status).toBe('published');
		});

		test('should reject publishing non-existent workshop', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			// Use a valid UUID format but non-existent ID
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'PATCH',
				'/api/workshops/00000000-0000-0000-0000-000000000000/publish',
				{}
			);

			expect(response.status()).toBe(404);
		});

		test('should reject publishing without authentication', async ({ request }) => {
			const response = await request.patch(`/api/workshops/${testWorkshop.id}/publish`);
			expect(response.status()).toBe(401);
		});

		test('should reject publishing with insufficient permissions', async ({ request, context }) => {
			await loginAsUser(context, memberUser.email);
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'PATCH',
				`/api/workshops/${testWorkshop.id}/publish`,
				{}
			);

			expect(response.status()).toBe(403);
		});

		test('should reject publishing already published workshop', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);

			// First publish the workshop
			await makeAuthenticatedRequest(
				request,
				context,
				'PATCH',
				`/api/workshops/${testWorkshop.id}/publish`,
				{}
			);

			// Try to publish again
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'PATCH',
				`/api/workshops/${testWorkshop.id}/publish`,
				{}
			);

			expect(response.status()).toBe(400);
		});
	});

	test.describe('Workshop Attendees API', () => {
		let testWorkshop: any;

		test.beforeEach(async () => {
			testWorkshop = await workshopHelper.createTestWorkshop('basic');
		});

		test('should get workshop attendees', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				`/api/workshops/${testWorkshop.id}/attendees`,
				{}
			);

			expect(response.status()).toBe(200);
			const attendees = await response.json();
			expect(Array.isArray(attendees)).toBe(true);
		});

		test('should add attendee to workshop', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${testWorkshop.id}/attendees`,
				{
					data: {
						user_profile_id: memberUser.profileId,
						priority: 1
					}
				}
			);

			expect(response.status()).toBe(200);
			const result = await response.json();
			expect(result.success).toBe(true);
			expect(result.attendee.user_profile_id).toBe(memberUser.profileId);
			expect(result.attendee.status).toBe('invited');
		});

		test('should reject adding attendee without authentication', async ({ request }) => {
			const response = await request.post(`/api/workshops/${testWorkshop.id}/attendees`, {
				data: {
					user_profile_id: memberUser.profileId,
					priority: 1
				}
			});

			expect(response.status()).toBe(401);
		});

		test('should reject adding attendee with insufficient permissions', async ({
			request,
			context
		}) => {
			await loginAsUser(context, memberUser.email);
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${testWorkshop.id}/attendees`,
				{
					data: {
						user_profile_id: memberUser.profileId,
						priority: 1
					}
				}
			);

			expect(response.status()).toBe(403);
		});
	});

	test.describe('Workshop User Search API', () => {
		let testWorkshop: any;

		test.beforeEach(async () => {
			testWorkshop = await workshopHelper.createTestWorkshop('basic');
		});

		test('should search for users to add to workshop', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				`/api/workshops/${testWorkshop.id}/search-users`,
				{
					params: { q: 'test' }
				}
			);

			expect(response.status()).toBe(200);
			const users = await response.json();
			expect(Array.isArray(users)).toBe(true);
		});

		test('should reject search without authentication', async ({ request }) => {
			const response = await request.get(`/api/workshops/${testWorkshop.id}/search-users?q=test`);
			expect(response.status()).toBe(401);
		});

		test('should reject search with insufficient permissions', async ({ request, context }) => {
			await loginAsUser(context, memberUser.email);
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				`/api/workshops/${testWorkshop.id}/search-users`,
				{
					params: { q: 'test' }
				}
			);

			expect(response.status()).toBe(403);
		});

		test('should reject search with query too short', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				`/api/workshops/${testWorkshop.id}/search-users`,
				{
					params: { q: 'a' }
				}
			);

			expect(response.status()).toBe(400);
		});
	});

	test.describe('Data Validation and Edge Cases', () => {
		test('should handle malformed UUID in workshop ID', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				'/api/workshops/invalid-uuid/attendees',
				{}
			);

			expect(response.status()).toBe(400);
		});

		test('should handle SQL injection attempts', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const maliciousPayload = {
				workshop_date: "2025-12-01T10:00:00Z'; DROP TABLE workshops; --",
				location: 'Test Location',
				coach_id: testCoach.id,
				capacity: 16
			};

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: maliciousPayload
			});

			// Should either reject with validation error or sanitize the input
			expect([400, 500]).toContain(response.status());
		});

		test('should handle empty string values', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const payload = {
				workshop_date: '',
				location: '',
				coach_id: '',
				capacity: 16
			};

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(400);
		});

		test('should handle null values', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const payload = {
				workshop_date: null,
				location: null,
				coach_id: null,
				capacity: null
			};

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(400);
		});
	});

	test.describe('Concurrent Operations', () => {
		test('should handle concurrent workshop creation', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			// Create multiple workshops concurrently
			const promises = Array.from({ length: 3 }, () =>
				makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
					data: payload
				})
			);

			const responses = await Promise.all(promises);

			// All should succeed or fail gracefully
			responses.forEach((response) => {
				expect([200, 409, 500]).toContain(response.status());
			});
		});

		test('should handle concurrent status changes', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const testWorkshop = await workshopHelper.createTestWorkshop('basic');

			// Try to publish the same workshop concurrently
			const promises = Array.from({ length: 2 }, () =>
				makeAuthenticatedRequest(
					request,
					context,
					'PATCH',
					`/api/workshops/${testWorkshop.id}/publish`,
					{}
				)
			);

			const responses = await Promise.all(promises);

			// One should succeed, others should handle gracefully
			const successCount = responses.filter((r) => r.status() === 200).length;
			expect(successCount).toBeGreaterThanOrEqual(1);
		});
	});
});
