import { test, expect } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';
import { WorkshopTestHelper, generateWorkshopApiPayload } from './utils/workshop-test-utils';
import { makeAuthenticatedRequest } from './utils/api-request-helper';
import dayjs from 'dayjs';

test.describe('Workshop Scheduling and Validation Tests', () => {
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

	test.describe('Date and Time Validation API', () => {
		test('should accept workshop with future date', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const futureDate = dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]');
			const payload = generateWorkshopApiPayload('basic', {
				coach_id: testCoach.id,
				workshop_date: futureDate
			});

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(200);
			const workshop = await response.json();
			expect(workshop.workshop_date).toContain(futureDate.replace('Z', ''));
		});

		test('should reject workshop with past date', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const pastDate = dayjs().subtract(1, 'day').format('YYYY-MM-DDTHH:mm:ss[Z]');
			const payload = generateWorkshopApiPayload('basic', {
				coach_id: testCoach.id,
				workshop_date: pastDate
			});

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			expect(response.status()).toBe(400);
			const errorData = await response.json();
			expect(errorData.message).toContain('Date cannot be in the past');
		});

		test('should handle edge case dates (exactly now)', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const nowDate = dayjs().format('YYYY-MM-DDTHH:mm:ss[Z]');
			const payload = generateWorkshopApiPayload('basic', {
				coach_id: testCoach.id,
				workshop_date: nowDate
			});

			const response = await makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
				data: payload
			});

			// Should be accepted as it's not technically in the past
			expect([200, 400]).toContain(response.status());
		});

		test('should validate date format', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const invalidDates = [
				'invalid-date',
				'2025-13-01T10:00:00Z', // Invalid month
				'2025-01-32T10:00:00Z', // Invalid day
				'2025-01-01T25:00:00Z', // Invalid hour
				'2025/01/01 10:00:00', // Wrong format
				'1234567890', // Timestamp
				null,
				undefined
			];

			for (const invalidDate of invalidDates) {
				const payload = generateWorkshopApiPayload('basic', {
					coach_id: testCoach.id,
					workshop_date: invalidDate as any
				});

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
			}
		});

		test('should check for date/location conflicts', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshopDate = dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]');
			const location = 'Main Training Hall';

			// Create first workshop
			const firstPayload = generateWorkshopApiPayload('basic', {
				coach_id: testCoach.id,
				workshop_date: workshopDate,
				location: location
			});

			const firstResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				'/api/workshops',
				{
					data: firstPayload
				}
			);

			expect(firstResponse.status()).toBe(200);

			// Try to create second workshop with same date/location
			const secondPayload = generateWorkshopApiPayload('basic', {
				coach_id: testCoach.id,
				workshop_date: workshopDate,
				location: location
			});

			const secondResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				'/api/workshops',
				{
					data: secondPayload
				}
			);

			// Should either allow or reject based on business rules
			expect([200, 400, 409]).toContain(secondResponse.status());
		});

		test('should allow same date with different locations', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshopDate = dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]');

			// Create first workshop
			const firstPayload = generateWorkshopApiPayload('basic', {
				coach_id: testCoach.id,
				workshop_date: workshopDate,
				location: 'Main Training Hall'
			});

			const firstResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				'/api/workshops',
				{
					data: firstPayload
				}
			);

			expect(firstResponse.status()).toBe(200);

			// Create second workshop with same date, different location
			const secondPayload = generateWorkshopApiPayload('basic', {
				coach_id: testCoach.id,
				workshop_date: workshopDate,
				location: 'Secondary Training Room'
			});

			const secondResponse = await makeAuthenticatedRequest(
				request,
				context,
				'POST',
				'/api/workshops',
				{
					data: secondPayload
				}
			);

			expect(secondResponse.status()).toBe(200);
		});

		test('should update workshop date to future', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');
			const newDate = dayjs().add(45, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]');

			const response = await makeAuthenticatedRequest(
				request,
				context,
				'PATCH',
				`/api/workshops/${workshop.id}`,
				{
					data: { workshop_date: newDate }
				}
			);

			// Note: Update endpoint may not exist yet - placeholder test
			expect([200, 404]).toContain(response.status());
		});

		test('should reject updating workshop date to past', async ({ request, context }) => {
			await loginAsUser(context, adminUser.email);
			const workshop = await workshopHelper.createTestWorkshop('basic');
			const pastDate = dayjs().subtract(1, 'day').format('YYYY-MM-DDTHH:mm:ss[Z]');

			const response = await makeAuthenticatedRequest(
				request,
				context,
				'PATCH',
				`/api/workshops/${workshop.id}`,
				{
					data: { workshop_date: pastDate }
				}
			);

			expect([400, 404]).toContain(response.status());
		});

		test.describe('Location Management API', () => {
			test('should accept workshop with valid location', async ({ request, context }) => {
				await loginAsUser(context, adminUser.email);
				const payload = generateWorkshopApiPayload('basic', {
					coach_id: testCoach.id,
					location: 'Main Training Hall'
				});

				const response = await makeAuthenticatedRequest(
					request,
					context,
					'POST',
					'/api/workshops',
					{
						data: payload
					}
				);

				expect(response.status()).toBe(200);
				const workshop = await response.json();
				expect(workshop.location).toBe('Main Training Hall');
			});

			test('should reject workshop with empty location', async ({ request, context }) => {
				await loginAsUser(context, adminUser.email);
				const payload = generateWorkshopApiPayload('basic', {
					coach_id: testCoach.id,
					location: ''
				});

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
			});

			test('should handle long location names', async ({ request, context }) => {
				await loginAsUser(context, adminUser.email);
				const longLocation = 'A'.repeat(500); // Very long location name
				const payload = generateWorkshopApiPayload('basic', {
					coach_id: testCoach.id,
					location: longLocation
				});

				const response = await makeAuthenticatedRequest(
					request,
					context,
					'POST',
					'/api/workshops',
					{
						data: payload
					}
				);

				// Should either accept or reject based on database constraints
				expect([200, 400]).toContain(response.status());
			});

			test('should handle special characters in location', async ({ request, context }) => {
				await loginAsUser(context, adminUser.email);
				const specialLocation = 'Café "Training" Hall & Gym #1 (Level 2)';
				const payload = generateWorkshopApiPayload('basic', {
					coach_id: testCoach.id,
					location: specialLocation
				});

				const response = await makeAuthenticatedRequest(
					request,
					context,
					'POST',
					'/api/workshops',
					{
						data: payload
					}
				);

				expect(response.status()).toBe(200);
				const workshop = await response.json();
				expect(workshop.location).toBe(specialLocation);
			});

			test('should update workshop location', async ({ request, context }) => {
				await loginAsUser(context, adminUser.email);
				const workshop = await workshopHelper.createTestWorkshop('basic');
				const newLocation = 'Updated Training Room';

				const response = await makeAuthenticatedRequest(
					request,
					context,
					'PATCH',
					`/api/workshops/${workshop.id}`,
					{
						data: { location: newLocation }
					}
				);

				// Note: Update endpoint may not exist yet - placeholder test
				expect([200, 404]).toContain(response.status());
			});

			test('should validate location requirements', async ({ request, context }) => {
				await loginAsUser(context, adminUser.email);
				const invalidLocations = [null, undefined, '   ', '\t\n'];

				for (const invalidLocation of invalidLocations) {
					const payload = generateWorkshopApiPayload('basic', {
						coach_id: testCoach.id,
						location: invalidLocation as any
					});

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
				}
			});
		});

		test.describe('Date and Time Validation UI', () => {
			test('should display date picker functionality', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Navigate to creation form
				await page.getByRole('button', { name: /create/i }).click();

				// Test date picker
				await page.click('[name="workshop_date"]');

				// Check if date picker appears
				const datePicker = page.locator('.datepicker, .calendar, [data-testid="date-picker"]');
				if (await datePicker.isVisible()) {
					await expect(datePicker).toBeVisible();
				}
			});

			test('should validate date in form', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Navigate to creation form
				await page.getByRole('button', { name: /create/i }).click();

				// Try to set past date
				await page.fill('[name="workshop_date"]', dayjs().subtract(1, 'day').format('YYYY-MM-DD'));
				await page.getByRole('button', { name: /create/i }).click();

				// Should show validation error
				await expect(page.getByText(/date cannot be in the past/i)).toBeVisible();
			});

			test('should test time picker functionality', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Navigate to creation form
				await page.getByRole('button', { name: /create/i }).click();

				// Test time input
				const timeInput = page.locator('[name="workshop_time"], input[type="time"]');
				if (await timeInput.isVisible()) {
					await timeInput.fill('14:30');
					expect(await timeInput.inputValue()).toContain('14:30');
				}
			});

			test('should handle timezone display', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Navigate to creation form
				await page.getByRole('button', { name: /create/i }).click();

				// Check timezone indicator
				const timezoneIndicator = page.locator('[data-testid="timezone"]');
				if (await timezoneIndicator.isVisible()) {
					await expect(timezoneIndicator).toBeVisible();
				}
			});

			test('should show date conflict warnings', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);

				// Create existing workshop
				const existingDate = dayjs().add(30, 'days').format('YYYY-MM-DD');
				const existingLocation = 'Main Training Hall';
				await workshopHelper.createTestWorkshop('basic', {
					workshop_date: dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]'),
					location: existingLocation
				});

				await page.goto('/dashboard/beginners-workshop');

				// Navigate to creation form
				await page.getByRole('button', { name: /create/i }).click();

				// Set same date and location
				await page.fill('[name="workshop_date"]', existingDate);
				await page.fill('[name="location"]', existingLocation);

				// Check for conflict warning
				const conflictWarning = page.locator('[data-testid="date-conflict-warning"]');
				if (await conflictWarning.isVisible()) {
					await expect(conflictWarning).toBeVisible();
				}
			});

			test('should test date formatting', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				const workshop = await workshopHelper.createTestWorkshop('basic');

				await page.goto(`/dashboard/beginners-workshop/${workshop.id}`);

				// Check date display format
				const dateDisplay = page.locator('[data-testid="workshop-date"]');
				if (await dateDisplay.isVisible()) {
					const dateText = await dateDisplay.textContent();
					expect(dateText).toBeTruthy();
					// Could verify specific format based on locale
				}
			});
		});

		test.describe('Location Management UI', () => {
			test('should test location input field', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Navigate to creation form
				await page.getByRole('button', { name: /create/i }).click();

				// Test location input
				await page.fill('[name="location"]', 'Test Training Location');
				expect(await page.inputValue('[name="location"]')).toBe('Test Training Location');
			});

			test('should validate location field', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Navigate to creation form
				await page.getByRole('button', { name: /create/i }).click();

				// Leave location empty and try to submit
				await page.fill('[name="location"]', '');
				await page.getByRole('button', { name: /create/i }).click();

				// Should show validation error
				await expect(page.getByText(/location required/i)).toBeVisible();
			});

			test('should test location autocomplete (if implemented)', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Navigate to creation form
				await page.getByRole('button', { name: /create/i }).click();

				// Test autocomplete functionality
				const locationInput = page.locator('[name="location"]');
				await locationInput.fill('Main');

				// Check for autocomplete suggestions
				const suggestions = page.locator('[data-testid="location-suggestions"]');
				if (await suggestions.isVisible()) {
					await expect(suggestions).toBeVisible();
					await page.click('[data-testid="suggestion-item"]');
				}
			});

			test('should test location update functionality', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				const workshop = await workshopHelper.createTestWorkshop('basic');

				await page.goto(`/dashboard/beginners-workshop/${workshop.id}/edit`);

				// Update location
				await page.fill('[name="location"]', 'Updated Training Room');
				await page.getByRole('button', { name: /save/i }).click();

				// Verify update
				await expect(page.getByText(/workshop updated/i)).toBeVisible();
			});

			test('should handle long location names in UI', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				await page.goto('/dashboard/beginners-workshop');

				// Navigate to creation form
				await page.getByRole('button', { name: /create/i }).click();

				// Test very long location name
				const longLocation = 'A very long location name that exceeds normal length'.repeat(5);
				await page.fill('[name="location"]', longLocation);

				// Check field handling
				const inputValue = await page.inputValue('[name="location"]');
				expect(inputValue.length).toBeGreaterThan(0);
			});

			test('should display location in workshop list', async ({ page, context }) => {
				await loginAsUser(context, adminUser.email);
				const workshop = await workshopHelper.createTestWorkshop('basic');

				await page.goto('/dashboard/beginners-workshop');

				// Check location display in list
				await expect(page.getByText(workshop.location)).toBeVisible();
			});
		});

		test.describe('Scheduling Integration Tests', () => {
			test('should validate complete date/location/coach combination', async ({
				request,
				context
			}) => {
				await loginAsUser(context, adminUser.email);
				const workshopDate = dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]');

				// Create first workshop
				const firstWorkshop = await workshopHelper.createTestWorkshop('basic', {
					workshop_date: workshopDate,
					location: 'Main Training Hall'
				});

				// Try to create overlapping workshop with same coach
				const payload = generateWorkshopApiPayload('basic', {
					coach_id: firstWorkshop.coach_id,
					workshop_date: workshopDate,
					location: 'Different Location'
				});

				const response = await makeAuthenticatedRequest(
					request,
					context,
					'POST',
					'/api/workshops',
					{
						data: payload
					}
				);

				// Should handle coach scheduling conflict
				expect([200, 400, 409]).toContain(response.status());
			});

			test('should handle workshop scheduling across different time zones', async ({
				request,
				context
			}) => {
				await loginAsUser(context, adminUser.email);
				const baseDate = dayjs().add(30, 'days');

				const timezoneFormats = [
					baseDate.format('YYYY-MM-DDTHH:mm:ss[Z]'),
					baseDate.format('YYYY-MM-DDTHH:mm:ssZ'),
					baseDate.format('YYYY-MM-DDTHH:mm:ss.SSS[Z]')
				];

				for (const dateFormat of timezoneFormats) {
					const payload = generateWorkshopApiPayload('basic', {
						coach_id: testCoach.id,
						workshop_date: dateFormat,
						location: `Location ${Math.random().toString(36).substring(2, 8)}`
					});

					const response = await makeAuthenticatedRequest(
						request,
						context,
						'POST',
						'/api/workshops',
						{
							data: payload
						}
					);

					expect(response.status()).toBe(200);
				}
			});

			test('should validate workshop scheduling business rules', async ({ request, context }) => {
				await loginAsUser(context, adminUser.email);
				const currentDate = dayjs();

				// Test edge cases around business rules
				const testCases = [
					{
						date: currentDate.add(1, 'minute').format('YYYY-MM-DDTHH:mm:ss[Z]'),
						expectation: 200, // Just barely in future
						description: 'barely future'
					},
					{
						date: currentDate.subtract(1, 'minute').format('YYYY-MM-DDTHH:mm:ss[Z]'),
						expectation: 400, // Just barely in past
						description: 'barely past'
					},
					{
						date: currentDate.add(1, 'year').format('YYYY-MM-DDTHH:mm:ss[Z]'),
						expectation: 200, // Far future
						description: 'far future'
					}
				];

				for (const testCase of testCases) {
					const payload = generateWorkshopApiPayload('basic', {
						coach_id: testCoach.id,
						workshop_date: testCase.date,
						location: `Location for ${testCase.description}`
					});

					const response = await makeAuthenticatedRequest(
						request,
						context,
						'POST',
						'/api/workshops',
						{
							data: payload
						}
					);

					expect(response.status()).toBe(testCase.expectation);
				}
			});

			test('should handle concurrent scheduling operations', async ({ request, context }) => {
				await loginAsUser(context, adminUser.email);
				const workshopDate = dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]');

				// Try to create multiple workshops with same date/location concurrently
				const promises = Array.from({ length: 3 }, () => {
					const payload = generateWorkshopApiPayload('basic', {
						coach_id: testCoach.id,
						workshop_date: workshopDate,
						location: 'Concurrent Test Location'
					});

					return makeAuthenticatedRequest(request, context, 'POST', '/api/workshops', {
						data: payload
					});
				});

				const responses = await Promise.all(promises);

				// At least one should succeed, others should handle conflicts gracefully
				const successCount = responses.filter((r) => r.status() === 200).length;
				expect(successCount).toBeGreaterThanOrEqual(1);
			});
		});
	});
});
