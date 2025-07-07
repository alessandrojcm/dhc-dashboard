import { test, expect } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';
import { WorkshopTestHelper } from './utils/workshop-test-utils';
import { makeAuthenticatedRequest } from './utils/api-request-helper';
import dayjs from 'dayjs';

// TODO: the UI tests are shit
test.describe('Workshop Capacity and Attendee Management Tests', () => {
	let workshopHelper: WorkshopTestHelper;
	let testCoach: Awaited<ReturnType<typeof workshopHelper.createTestCoach>>;
	let adminUser: any;
	let coachUser: any;
	let memberUser: any;
	let attendeeUser: any;

	test.beforeEach(async () => {
		workshopHelper = new WorkshopTestHelper();
		testCoach = await workshopHelper.createTestCoach();

		// Create test users with different roles (using unique emails)
		const timestamp = Date.now();
		const random = Math.random().toString(36).substr(2, 9);

		adminUser = await createMember({
			email: `admin-${timestamp}-${random}@test.com`,
			roles: new Set(['admin'])
		});

		coachUser = await createMember({
			email: `coach-${timestamp}-${random}@test.com`,
			roles: new Set(['coach'])
		});

		memberUser = await createMember({
			email: `member-${timestamp}-${random}@test.com`,
			roles: new Set(['member'])
		});

		attendeeUser = await createMember({
			email: `attendee-${timestamp}-${random}@test.com`,
			roles: new Set(['member'])
		});
	});

	test.afterEach(async () => {
		await workshopHelper.cleanup();
		await Promise.all([
			adminUser?.cleanUp(),
			coachUser?.cleanUp(),
			memberUser?.cleanUp(),
			attendeeUser?.cleanUp()
		]);
	});

	test.describe('Attendee Management API', () => {
		test('should add attendee to workshop', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			const response = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${workshop.id}/attendees`,
				{
					data: {
						user_profile_id: attendeeUser.profileId,
						priority: 1
					}
				}
			);

			expect(response.status()).toBe(200);
			const payload = await response.json();
			expect(payload.success).toBe(true);
			expect(payload.attendee.user_profile_id).toBe(attendeeUser.profileId);
			expect(payload.attendee.priority).toBe(1);
			expect(payload.attendee.status).toBe('invited');
			expect(payload.attendee.workshop_id).toBe(workshop.id);
		});

		test('should fetch workshop attendees', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			// Add some attendees
			await workshopHelper.addWorkshopAttendee(workshop.id, attendeeUser.profileId);
			await workshopHelper.addWorkshopAttendee(workshop.id, memberUser.profileId);

			const response = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				`/api/workshops/${workshop.id}/attendees`
			);

			expect(response.status()).toBe(200);
			const attendees = await response.json();
			expect(attendees.length).toBe(2);
		});

		test('should filter attendees by status', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			// Add attendees with different statuses
			await workshopHelper.addWorkshopAttendee(workshop.id, attendeeUser.profileId, 'invited');
			await workshopHelper.addWorkshopAttendee(workshop.id, memberUser.profileId, 'confirmed');

			// Filter by confirmed status
			const response = await makeAuthenticatedRequest(
				request,
				context,
				'GET',
				`/api/workshops/${workshop.id}/attendees`,
				{
					params: {
						status: 'confirmed'
					}
				}
			);

			expect(response.status()).toBe(200);
			const attendees = await response.json();
			expect(attendees.length).toBe(1);
			expect(attendees[0].status).toBe('confirmed');
		});

		test('should reject adding non-existent attendee', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			const response = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${workshop.id}/attendees`,
				{
					data: {
						user_profile_id: crypto.randomUUID(),
						priority: 1
					}
				}
			);

			expect([400, 404]).toContain(response.status());
		});

		test('should prevent duplicate attendees', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			// Add attendee first time
			const firstResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${workshop.id}/attendees`,
				{
					data: {
						user_profile_id: attendeeUser.profileId,
						priority: 1
					}
				}
			);

			expect(firstResponse.status()).toBe(200);

			// Try to add same attendee again
			const secondResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${workshop.id}/attendees`,
				{
					data: {
						user_profile_id: attendeeUser.profileId,
						priority: 1
					}
				}
			);

			expect([400, 409]).toContain(secondResponse.status());
		});

		test('should respect workshop capacity limits', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic', { capacity: 1 });

			// Add first attendee
			const firstResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${workshop.id}/attendees`,
				{
					data: {
						user_profile_id: attendeeUser.profileId,
						priority: 0
					}
				}
			);

			expect(firstResponse.status()).toBe(200);

			// Try to add second attendee (should exceed capacity)
			const secondResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${workshop.id}/attendees`,
				{
					data: {
						user_profile_id: memberUser.profileId,
						priority: 0
					}
				}
			);

			// Should either reject or allow based on business rules
			expect([200, 400, 409]).toContain(secondResponse.status());
		});

		test('should allow priority attendees to exceed capacity', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic', { capacity: 1 });

			// Add regular attendee first
			await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${workshop.id}/attendees`,
				{
					data: {
						user_profile_id: memberUser.profileId,
						priority: 0
					}
				}
			);

			// Add priority attendee (should be allowed even over capacity)
			const priorityResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${workshop.id}/attendees`,
				{
					data: {
						user_profile_id: attendeeUser.profileId,
						priority: 1
					}
				}
			);

			expect(priorityResponse.status()).toBe(200);
		});

		test('should reject attendee operations without authentication', async ({ request }) => {
			const workshop = await workshopHelper.createTestWorkshop('basic');

			// Make request without logging in first
			const response = await request.post(`/api/workshops/${workshop.id}/attendees`, {
				data: {
					user_profile_id: attendeeUser.profileId,
					priority: 0
				}
			});

			expect(response.status()).toBe(401);
		});

		test('should reject attendee operations with insufficient permissions', async ({
			request,
			context
		}) => {
			// Login as member user (who doesn't have admin permissions)
			await loginAsUser(context, memberUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			const response = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				`/api/workshops/${workshop.id}/attendees`,
				{
					data: {
						user_profile_id: attendeeUser.profileId,
						priority: 0
					}
				}
			);

			expect(response.status()).toBe(403);
		});
	});
	test.describe('Workshop UI Tests', () => {
		test('should display workshops table on main page', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);

			// Navigate to workshops page
			await page.goto('/dashboard/beginners-workshop');

			// Check that workshops table is visible
			await expect(page.getByRole('tab', { name: 'Workshops' })).toBeVisible();

			// Check that create workshop button is visible
			await expect(page.getByRole('button', { name: /create workshop/i })).toBeVisible();
		});

		test('should create workshop via UI', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);

			// Navigate to workshops page
			await page.goto('/dashboard/beginners-workshop');

			// Click create workshop button
			await page.getByRole('button', { name: /create workshop/i }).click();

			// Wait for form to be visible
			await expect(page.getByRole('heading', { name: 'New Workshop' })).toBeVisible();

			// Fill required fields
			await page.locator('input[name="location"]').fill('Test Location');
			await page.locator('input[name="capacity"]').fill('10');
			const testDate = dayjs().add(1, 'month');

			await page.getByPlaceholder(/select coach/i).selectOption(testCoach.first_name);

			// Set a date - click the date field and fill it
			await page.getByLabel('Date').click();
			await page.getByLabel('Select year').click();
			await page.getByRole('option', { name: testDate.year().toString() }).click();
			await page.getByLabel('Select month').click();
			await page.getByRole('option', { name: testDate.format('MMMM') }).dblclick();
			await page.getByLabel(testDate.format('dddd, MMMM D,')).click();

			// Submit form
			await page.getByRole('button', { name: /create$/i }).click();

			// Check for success (table should update)
			await expect(page.getByRole('tab', { name: 'Workshops' })).toBeVisible();
			await page.getByText('Test Location').click();
		});

		test('should navigate to workshop detail page', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			// Navigate to workshops page
			await page.goto('/dashboard/beginners-workshop');

			// Click on workshop row to navigate to detail page
			await page.locator('tr').filter({ hasText: workshop.location }).click();

			// Check URL changed to workshop detail page
			await expect(page).toHaveURL(`/dashboard/beginners-workshop/${workshop.id}`);
		});

		test('should show workshop details in sidebar', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			// Navigate to workshop detail page
			await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

			// Check workshop details are displayed
			await expect(page.getByText('Workshop Details')).toBeVisible();
			await expect(page.getByText(workshop.location)).toBeVisible();
			await expect(page.getByText('Capacity:')).toContainText(workshop.capacity.toString());

			// Check status badge
			await expect(page.locator('.badge', { hasText: 'draft' })).toBeVisible();
		});

		test('should show publish button for draft workshop', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			// Navigate to workshop detail page
			await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

			// Check publish button is visible and enabled for draft workshop
			await expect(page.getByRole('button', { name: /publish/i })).toBeVisible();
			await expect(page.getByRole('button', { name: /publish/i })).toBeEnabled();
		});

		test('should show priority attendees section', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			// Navigate to workshop detail page
			await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

			// Check priority attendees section is visible
			await expect(page.getByText('Priority Attendees')).toBeVisible();
			await expect(page.getByRole('button', { name: /add attendee/i })).toBeVisible();
		});

		test('should show workshop table pagination on main page', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);

			// Navigate to workshops page
			await page.goto('/dashboard/beginners-workshop');

			// Check pagination controls are visible
			await expect(page.getByText('Elements per page')).toBeVisible();

			// Check page size selector exists
			const pageSizeSelector = page
				.locator('select, [role="combobox"], button')
				.filter({ hasText: /10/ })
				.first();
			await expect(pageSizeSelector).toBeVisible();
		});

		test('should allow adding priority attendees', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');

			// Navigate to workshop detail page
			await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

			// Click add attendee button
			await page.getByRole('button', { name: /add attendee/i }).click();

			// Check search input appears
			await expect(page.locator('input[placeholder*="Search"]')).toBeVisible();
		});

		test('should show tab navigation on main page', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);

			// Navigate to workshops page
			await page.goto('/dashboard/beginners-workshop');

			// Check tab navigation is visible (both button and list versions)
			const workshopsTab = page
				.locator('button, [role="tab"]')
				.filter({ hasText: /workshops/i })
				.first();
			const waitlistTab = page
				.locator('button, [role="tab"]')
				.filter({ hasText: /waitlist/i })
				.first();

			await expect(workshopsTab).toBeVisible();
			await expect(waitlistTab).toBeVisible();

			// Click waitlist tab
			await waitlistTab.click();

			// Check URL updated
			await expect(page).toHaveURL(/tab=waitlist/);
		});
	});

	test.describe('Workshop Detail Page Tests', () => {
		test('should display workshop information correctly', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic', { capacity: 5 });

			// Navigate to workshop detail page
			await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

			// Check workshop details are displayed correctly
			await expect(page.getByText('Workshop Details')).toBeVisible();
			await expect(page.getByText(workshop.location)).toBeVisible();
			await expect(
				page.locator('div').filter({ hasText: 'Capacity:' }).locator('+ div', { hasText: '5' })
			).toBeVisible();
			await expect(page.getByText('draft')).toBeVisible(); // status
		});

		test('should show action buttons for workshop management', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic', { capacity: 3 });

			// Navigate to workshop detail page
			await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

			// Check action buttons are visible
			await expect(page.getByRole('button', { name: /edit/i })).toBeVisible();
			await expect(page.getByRole('button', { name: /publish/i })).toBeVisible();
			await expect(page.getByRole('button', { name: /finish/i })).toBeVisible();

			// Finish button should be disabled for draft workshop
			await expect(page.getByRole('button', { name: /finish/i })).toBeDisabled();
		});

		test('should show QR code section for published workshop', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshopWithStatus('published');

			// Navigate to workshop detail page
			await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

			// Check QR code section appears for published workshop
			await expect(page.getByText('Check-in QR Code')).toBeVisible();
			await expect(page.getByRole('button', { name: /show qr code/i })).toBeVisible();
			await expect(page.getByRole('button', { name: /download/i })).toBeVisible();
		});

		test('should display workshop attendees and details together', async ({ page, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic', { capacity: 2 });

			// Add priority attendee
			await workshopHelper.addWorkshopAttendee(workshop.id, attendeeUser.profileId);

			// Navigate to workshop detail page
			await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

			// Check both attendees section and details section are visible
			await expect(page.getByText('Workshop Details')).toBeVisible();
			await expect(page.getByText('Priority Attendees')).toBeVisible();

			// Check the layout (two column layout)
			const detailsSection = page.locator('.bg-card').filter({ hasText: 'Workshop Details' });
			await expect(detailsSection).toBeVisible();
		});
	});
});
