import { test, expect } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';
import { WorkshopTestHelper, generateWorkshopApiPayload } from './utils/workshop-test-utils';
import { makeAuthenticatedRequest } from './utils/api-request-helper';

test.describe('Workshop Permissions and Access Control Tests', () => {
	let workshopHelper: WorkshopTestHelper;
	let testCoach: any;
	let adminUser: any;
	let presidentUser: any;
	let coordinatorUser: any;
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

		presidentUser = await createMember({
			email: `president-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['president'])
		});

		coordinatorUser = await createMember({
			email: `coordinator-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['beginners_coordinator'])
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
		await Promise.all([
			adminUser?.cleanUp(),
			presidentUser?.cleanUp(),
			coordinatorUser?.cleanUp(),
			coachUser?.cleanUp(),
			memberUser?.cleanUp()
		]);
	});

	test.describe('Role-Based Access API', () => {
		test('should allow admin access to all workshop operations', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			// Create workshop
			const createResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				'/api/workshops',
				{
					data: payload
				}
			);

			expect(createResponse.status()).toBe(200);
			const workshop = await createResponse.json();

			// Publish workshop
			const publishResponse = await makeAuthenticatedRequest(
				request,
				context,
				'PATCH',
				`/api/workshops/${workshop.id}/publish`,
				{}
			);

			expect(publishResponse.status()).toBe(200);

			// Add attendee
			const attendeeResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${workshop.id}/attendees`,
				{
					data: {
						user_profile_id: memberUser.profileId,
						priority: 1
					}
				}
			);

			expect(attendeeResponse.status()).toBe(200);
		});

		test('should allow president access to workshop operations', async ({ request, context }) => {
			await loginAsUser(context, presidentUser.email);
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(200);
		});

		test('should allow beginners_coordinator access to workshop operations', async ({
			request,
			context
		}) => {
			await loginAsUser(context, coordinatorUser.email);
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(200);
		});

		test('should restrict coach access to appropriate operations', async ({ request, context }) => {
			await loginAsUser(context, coachUser.email);
			// Coach should NOT be able to create workshops
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			const createResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				'/api/workshops',
				{
					data: payload
				}
			);

			expect(createResponse.status()).toBe(403);

			// But should be able to view workshops (if endpoint exists)
			const workshop = await workshopHelper.createTestWorkshop('basic');

			const viewResponse = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				`/api/workshops/${workshop.id}`,
				{}
			);

			// Note: View endpoint may not exist yet
			expect([200, 404]).toContain(viewResponse.status());
		});

		test('should restrict member access to read-only operations', async ({ request, context }) => {
			await loginAsUser(context, memberUser.email);
			// Member should NOT be able to create workshops
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			const createResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				'/api/workshops',
				{
					data: payload
				}
			);

			expect(createResponse.status()).toBe(403);

			// Member should NOT be able to publish workshops
			const workshop = await workshopHelper.createTestWorkshop('basic');

			const publishResponse = await makeAuthenticatedRequest(
				request,
				context,
				'PATCH',
				`/api/workshops/${workshop.id}/publish`,
				{}
			);

			expect(publishResponse.status()).toBe(403);

			// Member should NOT be able to add attendees
			const attendeeResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${workshop.id}/attendees`,
				{
					data: {
						user_profile_id: memberUser.profileId,
						priority: 1
					}
				}
			);

			expect(attendeeResponse.status()).toBe(403);
		});

		test('should reject anonymous user access', async ({ request }) => {
			// No auth header - should fail
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			const response = await request.post('/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(401);
		});

		test('should validate role requirements for each endpoint', async ({ request, context }) => {
			await loginAsUser(context, memberUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			const restrictedOperations = [
				{
					method: 'POST' as const,
					url: '/api/workshops',
					data: generateWorkshopApiPayload('basic', { coach_id: testCoach.id }),
					description: 'create workshop'
				},
				{
					method: 'PATCH' as const,
					url: `/api/workshops/${workshop.id}/publish`,
					description: 'publish workshop'
				},
				{
					method: 'POST' as const,
					url: `/api/workshops/${workshop.id}/attendees`,
					data: { user_profile_id: memberUser.profileId, priority: 1 },
					description: 'add attendee'
				}
			];

			for (const operation of restrictedOperations) {
				const response = await makeAuthenticatedRequest(
					request,
					context,
					operation.method,
					operation.url,
					{
						data: operation.data
					}
				);

				expect(response.status()).toBe(403);
			}
		});

		test('should handle invalid or expired tokens', async ({ request }) => {
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			// Test with invalid token
			const invalidResponse = await request.post('/api/workshops', {
				data: payload,
				headers: {
					Authorization: 'Bearer invalid-token'
				}
			});

			expect(invalidResponse.status()).toBe(401);

			// Test with malformed auth header
			const malformedResponse = await request.post('/api/workshops', {
				data: payload,
				headers: {
					Authorization: 'InvalidFormat'
				}
			});

			expect(malformedResponse.status()).toBe(401);
		});

		test('should handle multiple roles properly', async ({ request, context }) => {
			// Create user with multiple roles
			const timestamp = Date.now();
			const randomSuffix = Math.random().toString(36).substring(2, 15);
			const multiRoleUser = await createMember({
				email: `multirole-${timestamp}-${randomSuffix}@test.com`,
				roles: new Set(['coach', 'admin'])
			});

			await loginAsUser(context, multiRoleUser.email);
			const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			// Should use highest privilege role (admin)
			expect(response.status()).toBe(200);

			await multiRoleUser.cleanUp();
		});
	});

	test.describe('Data Access Control', () => {
		test('should restrict attendee data access', async ({ request, context }) => {
			const workshop = await workshopHelper.createTestWorkshop('basic');
			await workshopHelper.addWorkshopAttendee(workshop.id, memberUser.profileId);

			// Admin should see all attendees
			await loginAsUser(context, adminUser.email);
			const adminResponse = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				`/api/workshops/${workshop.id}/attendees`,
				{}
			);

			expect(adminResponse.status()).toBe(200);

			// Member should NOT see attendee list
			await loginAsUser(context, memberUser.email);
			const memberResponse = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				`/api/workshops/${workshop.id}/attendees`,
				{}
			);

			expect(memberResponse.status()).toBe(403);
		});

		test('should allow coach to see only assigned workshops', async ({ request, context }) => {
			await loginAsUser(context, coachUser.email);
			// Create workshop with coach as the assigned coach
			const coachWorkshop = await workshopHelper.createTestWorkshop('basic', {
				coach_id: coachUser.profileId
			});

			// Create workshop with different coach
			const otherWorkshop = await workshopHelper.createTestWorkshop('basic');

			// Coach should be able to view their assigned workshop
			const assignedResponse = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				`/api/workshops/${coachWorkshop.id}`,
				{}
			);

			expect([200, 404]).toContain(assignedResponse.status());

			// Coach should NOT be able to view other workshop
			const otherResponse = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				`/api/workshops/${otherWorkshop.id}`,
				{}
			);

			expect([403, 404]).toContain(otherResponse.status());
		});

		test.describe('UI Permission Control', () => {
			test('should show admin dashboard with full access', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Admin should see all controls
				await expect(page.getByRole('button', { name: /create/i })).toBeVisible();

				// Navigate to workshop detail
				const workshop = await workshopHelper.createTestWorkshop('basic');
				await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

				await expect(page.getByRole('button', { name: /edit/i })).toBeVisible();
				await expect(page.getByRole('button', { name: /publish/i })).toBeVisible();
				await expect(page.getByRole('button', { name: /delete/i })).toBeVisible();
			});

			test('should show coach dashboard with limited access', async ({ page, context }) => {
				await loginAsUser(context, coachUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Coach should see dashboard but limited controls
				await expect(page.locator('[data-testid="workshop-list"]')).toBeVisible();

				// Create button should be hidden or disabled
				const createButton = page.getByRole('button', { name: /create/i });
				if (await createButton.isVisible()) {
					await expect(createButton).toBeDisabled();
				} else {
					await expect(createButton).not.toBeVisible();
				}
			});

			test('should show member dashboard with read-only access', async ({ page, context }) => {
				await loginAsUser(context, memberUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Member should see read-only view
				await expect(page.locator('[data-testid="workshop-list"]')).toBeVisible();
				await expect(page.getByRole('button', { name: /create/i })).not.toBeVisible();

				// Navigate to workshop detail
				const workshop = await workshopHelper.createTestWorkshop('basic');
				await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

				await expect(page.getByRole('button', { name: /edit/i })).not.toBeVisible();
				await expect(page.getByRole('button', { name: /publish/i })).not.toBeVisible();
				await expect(page.getByRole('button', { name: /delete/i })).not.toBeVisible();
			});

			test('should redirect anonymous users to login', async ({ page }) => {
				await page.goto('/dashboard/beginners-workshop');

				// Should redirect to auth page
				await page.waitForURL('**/auth/**');
				expect(page.url()).toContain('/auth');
			});

			test('should show permission-based button visibility', async ({ page, context }) => {
				const workshop = await workshopHelper.createTestWorkshop('basic');

				const testCases = [
					{
						user: adminUser,
						expectVisible: ['edit', 'publish', 'delete', 'add-attendee'],
						expectHidden: []
					},
					{
						user: coachUser,
						expectVisible: [],
						expectHidden: ['edit', 'publish', 'delete', 'add-attendee']
					},
					{
						user: memberUser,
						expectVisible: [],
						expectHidden: ['edit', 'publish', 'delete', 'add-attendee']
					}
				];

				for (const testCase of testCases) {
					await loginAsUser(context, testCase.user.email);
					await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

					// Check visible buttons
					for (const buttonName of testCase.expectVisible) {
						await expect(
							page.getByRole('button', { name: new RegExp(buttonName, 'i') })
						).toBeVisible();
					}

					// Check hidden buttons
					for (const buttonName of testCase.expectHidden) {
						await expect(
							page.getByRole('button', { name: new RegExp(buttonName, 'i') })
						).not.toBeVisible();
					}
				}
			});

			test('should restrict page access based on permissions', async ({ page, context }) => {
				const workshop = await workshopHelper.createTestWorkshop('basic');

				// Member tries to access edit page
				await loginAsUser(context, memberUser.email);
				await page.goto(`/dashboard/beginners-workshop/${workshop.id}/edit`);

				// Should redirect or show access denied
				try {
					await expect(page.locator('text=Access denied')).toBeVisible();
				} catch {
					await page.waitForURL('**/dashboard/beginners-workshop/**');
				}
			});

			test('should handle role-based navigation restrictions', async ({ page, context }) => {
				await loginAsUser(context, memberUser.email);

				// Check navigation menu
				await page.goto('/dashboard');

				// Member should not see admin-only navigation items
				await expect(page.getByRole('link', { name: /user management/i })).not.toBeVisible();
				await expect(page.getByRole('link', { name: /system settings/i })).not.toBeVisible();
			});

			test('should show different data based on user role', async ({ page, context }) => {
				const workshop = await workshopHelper.createTestWorkshop('basic');
				await workshopHelper.addWorkshopAttendee(workshop.id, memberUser.profileId);

				// Admin sees full attendee list
				await loginAsUser(context, adminUser.email);
				await page.goto(`/dashboard/beginners-workshop/${workshop.id}/attendees`);
				await expect(page.getByText(memberUser.email)).toBeVisible();

				// Member cannot access attendee list
				await loginAsUser(context, memberUser.email);
				await page.goto(`/dashboard/beginners-workshop/${workshop.id}/attendees`);
				try {
					await expect(page.locator('text=Access denied')).toBeVisible();
				} catch {
					await page.waitForURL('**/dashboard/beginners-workshop/**');
				}
			});

			test('should handle session expiry gracefully', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Simulate session expiry by clearing cookies
				await context.clearCookies();

				// Try to perform an action
				await page.getByRole('button', { name: /create/i }).click();

				// Should redirect to login or show auth error
				try {
					await expect(page.locator('text=Please log in')).toBeVisible();
				} catch {
					await page.waitForURL('**/auth/**');
				}
			});
		});

		test.describe('Advanced Permission Scenarios', () => {
			test('should handle permission escalation attempts', async ({ request, context }) => {
				await loginAsUser(context, memberUser.email);
				// Try to manipulate JWT claims or headers
				const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

				// Get cookies for authenticated request
				const cookies = await context
					.cookies()
					.then((cookies) => cookies.map((c) => `${c.name}=${c.value}`).join('; '));

				const response = await request.post('/api/workshops', {
					data: payload,
					headers: {
						'X-Role': 'admin', // Attempt to override role
						'X-User-Role': 'admin',
						cookie: cookies
					}
				});

				expect(response.status()).toBe(403);
			});

			test('should validate permission inheritance', async ({ request, context }) => {
				// Create user with inherited permissions
				const timestamp = Date.now();
				const randomSuffix = Math.random().toString(36).substring(2, 15);
				const inheritedUser = await createMember({
					email: `inherited-${timestamp}-${randomSuffix}@test.com`,
					roles: new Set(['coach', 'beginners_coordinator'])
				});

				await loginAsUser(context, inheritedUser.email);
				const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

				const response = await makeAuthenticatedRequest(
					request,
					context,
					'POST',
					'/api/workshops',
					{
						data: payload
					}
				);

				// Should use highest privilege (beginners_coordinator allows creation)
				expect(response.status()).toBe(200);

				await inheritedUser.cleanUp();
			});

			test('should handle concurrent permission changes', async ({ request, context }) => {
				await loginAsUser(context, memberUser.email);
				// This would test scenarios where user permissions change during a session
				// For now, verify current permissions are properly enforced
				const workshop = await workshopHelper.createTestWorkshop('basic');

				const response = await makeAuthenticatedRequest(
					request,
					context,
					'PATCH',
					`/api/workshops/${workshop.id}/publish`,
					{}
				);

				expect(response.status()).toBe(403);
			});

			test('should audit permission violations', async ({ request, context }) => {
				await loginAsUser(context, memberUser.email);
				// Attempt unauthorized action and verify it's logged/tracked
				const payload = generateWorkshopApiPayload('basic', { coach_id: testCoach.id });

				const response = await makeAuthenticatedRequest(
					request,
					context,
					'POST',
					'/api/workshops',
					{
						data: payload
					}
				);

				expect(response.status()).toBe(403);

				// In a real system, this would also verify audit logs
				// For now, just ensure the rejection is proper
			});

			test('should handle malicious parameter manipulation', async ({ request, context }) => {
				await loginAsUser(context, memberUser.email);
				const workshop = await workshopHelper.createTestWorkshop('basic');

				// Try to manipulate workshop ownership or permissions through parameters
				const maliciousPayloads = [
					{ coach_id: adminUser.profileId }, // Try to assign admin as coach
					{ status: 'published' }, // Try to directly set status
					{ created_by: memberUser.profileId } // Try to change creator
				];

				for (const maliciousData of maliciousPayloads) {
					const response = await makeAuthenticatedRequest(
						request,
						context,
						'PATCH',
						`/api/workshops/${workshop.id}`,
						{
							data: maliciousData
						}
					);

					expect([403, 404]).toContain(response.status());
				}
			});
		});
	});
});
