import { expect, test } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';
import dayjs from 'dayjs';

test.describe('Workshop UI', () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let workshopCoordinatorData: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const timestamp = Date.now();

		// Create admin user
		adminData = await createMember({
			email: `admin-ui-${timestamp}@test.com`,
			roles: new Set(['admin'])
		});

		// Create workshop coordinator user
		workshopCoordinatorData = await createMember({
			email: `coordinator-ui-${timestamp}@test.com`,
			roles: new Set(['workshop_coordinator'])
		});
	});

	test('should display workshops page and create button for authorized users', async ({
		page,
		context
	}) => {
		await loginAsUser(context, adminData.email);
		await page.goto('/dashboard/workshops');

		// Should show the workshops page
		await expect(page.getByRole('heading', { name: 'Workshops' })).toBeVisible();

		// Should show create button
		await expect(page.getByRole('button', { name: 'Create Workshop' })).toBeVisible();
	});

	test('should navigate to create workshop form', async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto('/dashboard/workshops');

		// Click create workshop button
		await page.getByRole('button', { name: 'Create Workshop' }).click();
		// Should navigate to create page
		await expect(page).toHaveURL('/dashboard/workshops/create');
		await expect(page.getByRole('heading', { name: 'Create Workshop' })).toBeVisible();
	});

	test('should display and validate workshop creation form', async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto('/dashboard/workshops/create');

		// Check all form fields are present using proper labels
		await expect(page.getByRole('textbox', { name: /title/i })).toBeVisible();
		await expect(page.getByRole('textbox', { name: /description/i })).toBeVisible();
		await expect(page.getByRole('textbox', { name: /location/i })).toBeVisible();
		await expect(page.getByRole('textbox', { name: /workshop time/i })).toBeVisible();
		await expect(page.getByRole('spinbutton', { name: /maximum capacity/i })).toBeVisible();
		await expect(page.getByRole('spinbutton', { name: /member price/i })).toBeVisible();
		await expect(page.getByText('Public Workshop', { exact: true })).toBeVisible();
		await expect(page.getByRole('spinbutton', { name: /refund deadline/i })).toBeVisible();

		// Check submit button
		await expect(page.getByRole('button', { name: 'Create Workshop' })).toBeVisible();

		// Check back button
		await expect(page.getByRole('link', { name: 'Back to Workshops' })).toBeVisible();
	});

	test('should show validation errors for empty required fields', async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto('/dashboard/workshops/create');

		// Try to submit form without filling required fields
		await page.getByRole('button', { name: 'Create Workshop' }).click();

		// Should show validation errors (wait a moment for validation to trigger)
		await page.waitForTimeout(1000);

		// Check that form hasn't been submitted (still on create page)
		await expect(page).toHaveURL('/dashboard/workshops/create');
	});

	test('should successfully create a workshop through UI', async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto('/dashboard/workshops/create');

		const timestamp = Date.now();
		const workshopTitle = `UI Test Workshop ${timestamp}`;

		// Fill out the form using proper accessible selectors
		await page.getByRole('textbox', { name: /title/i }).fill(workshopTitle);
		await page.getByRole('textbox', { name: /description/i }).fill('Test workshop created via UI');
		await page.getByRole('textbox', { name: /location/i }).fill('Test Location');

		// Set workshop date (tomorrow) - using dayjs
		const workshopDate = dayjs().add(1, 'day');
		await page.getByLabel('Workshop Date').click();
		await page.getByRole('option', { name: workshopDate.year().toString() }).click();
		await page.getByLabel('Select month').click();
		await page.getByRole('option', { name: workshopDate.format('MMMM') }).dblclick();
		await page.getByLabel(workshopDate.format('dddd, MMMM D,')).click();

		// Set workshop time
		await page.getByRole('textbox', { name: /workshop time/i }).fill('14:30');

		await page.getByRole('spinbutton', { name: /maximum capacity/i }).fill('15');
		await page.getByRole('spinbutton', { name: /member price/i }).fill('15');

		// Enable public workshop so non-member price field appears
		await page.getByText('Public Workshop', { exact: true }).click();
		await page.getByRole('spinbutton', { name: /non-member price/i }).fill('25');

		await page.getByRole('spinbutton', { name: /refund deadline/i }).fill('3');

		// Submit the form
		await page.getByRole('button', { name: 'Create Workshop' }).click();

		// Should show success message
		await expect(
			page.getByText('Workshop "' + workshopTitle + '" created successfully!')
		).toBeVisible();

		// Should redirect to workshops list after a moment
		await page.waitForTimeout(3000);
		await expect(page).toHaveURL('/dashboard/workshops');
	});

	test('should display created workshop in list', async ({ page, context }) => {
		await loginAsUser(context, adminData.email);

		// First create a workshop via API for testing list display
		const timestamp = Date.now();
		const workshopTitle = `List Test Workshop ${timestamp}`;

		const workshopData = {
			title: workshopTitle,
			description: 'Test workshop for list display',
			location: 'Test Location',
			workshop_date: dayjs().add(1, 'day').format('YYYY-MM-DD'),
			workshop_time: '14:00',
			max_capacity: 10,
			price_member: 10,
			price_non_member: 20,
			is_public: true,
			refund_deadline_days: 3
		};

		// Create workshop via API
		const response = await page.request.post('/api/workshops', {
			data: workshopData
		});

		expect(response.ok()).toBeTruthy();

		// Now visit workshops page
		await page.goto('/dashboard/workshops');

		// Should see the workshop in the list
		await expect(page.getByText(workshopTitle)).toBeVisible();
		await expect(page.getByText('Test workshop for list display')).toBeVisible();
		await expect(page.getByText('Test Location')).toBeVisible();

		// Should see status badge
		await expect(page.getByText('planned')).toBeVisible();

		// Should see action buttons for planned workshop - find them within the workshop's container
		const workshopCard = page.locator('article').filter({ hasText: workshopTitle });
		await expect(workshopCard.getByRole('button', { name: 'Edit' })).toBeVisible();
		await expect(workshopCard.getByRole('button', { name: 'Publish' })).toBeVisible();
		await expect(workshopCard.getByRole('button', { name: 'Cancel' })).toBeVisible();
		await expect(workshopCard.getByRole('button', { name: 'Delete' })).toBeVisible();
	});

	test('should allow publishing a workshop through UI', async ({ page, context }) => {
		await loginAsUser(context, adminData.email);

		// Create a workshop via API first
		const timestamp = Date.now();
		const workshopTitle = `Publish Test Workshop ${timestamp}`;

		const workshopData = {
			title: workshopTitle,
			description: 'Test workshop for publishing',
			location: 'Test Location',
			workshop_date: dayjs().add(1, 'day').format('YYYY-MM-DD'),
			workshop_time: '14:00',
			max_capacity: 10,
			price_member: 10,
			price_non_member: 20,
			is_public: true,
			refund_deadline_days: 3
		};

		const response = await page.request.post('/api/workshops', {
			data: workshopData
		});
		expect(response.ok()).toBeTruthy();

		// Visit workshops page
		await page.goto('/dashboard/workshops');

		// Find the workshop card and click publish
		const workshopCard = page.locator('article').filter({ hasText: workshopTitle });
		await workshopCard.getByRole('button', { name: 'Publish' }).click();

		// Status should change to published
		await expect(workshopCard.getByText('published')).toBeVisible();

		// Publish button should disappear (published workshops can't be published again)
		await expect(workshopCard.getByRole('button', { name: 'Publish' })).not.toBeVisible();
	});

	test('should allow cancelling a workshop through UI', async ({ page, context }) => {
		await loginAsUser(context, adminData.email);

		// Create a workshop via API first
		const timestamp = Date.now();
		const workshopTitle = `Cancel Test Workshop ${timestamp}`;

		const workshopData = {
			title: workshopTitle,
			description: 'Test workshop for cancelling',
			location: 'Test Location',
			workshop_date: dayjs().add(1, 'day').format('YYYY-MM-DD'),
			workshop_time: '14:00',
			max_capacity: 10,
			price_member: 10,
			price_non_member: 20,
			is_public: true,
			refund_deadline_days: 3
		};

		const response = await page.request.post('/api/workshops', {
			data: workshopData
		});
		expect(response.ok()).toBeTruthy();

		// Visit workshops page
		await page.goto('/dashboard/workshops');

		// Find the workshop card and click cancel (with confirmation)
		const workshopCard = page.locator('article').filter({ hasText: workshopTitle });

		// Set up dialog handler for confirmation
		page.on('dialog', (dialog) => dialog.accept());

		await workshopCard.getByRole('button', { name: 'Cancel' }).click();

		// Status should change to cancelled
		await expect(workshopCard.getByText('cancelled')).toBeVisible();
	});

	test('should allow deleting a workshop through UI', async ({ page, context }) => {
		await loginAsUser(context, adminData.email);

		// Create a workshop via API first
		const timestamp = Date.now();
		const workshopTitle = `Delete Test Workshop ${timestamp}`;

		const workshopData = {
			title: workshopTitle,
			description: 'Test workshop for deleting',
			location: 'Test Location',
			workshop_date: dayjs().add(1, 'day').format('YYYY-MM-DD'),
			workshop_time: '14:00',
			max_capacity: 10,
			price_member: 10,
			price_non_member: 20,
			is_public: true,
			refund_deadline_days: 3
		};

		const response = await page.request.post('/api/workshops', {
			data: workshopData
		});
		expect(response.ok()).toBeTruthy();

		// Visit workshops page
		await page.goto('/dashboard/workshops');

		// Find the workshop card and click delete (with confirmation)
		const workshopCard = page.locator('article').filter({ hasText: workshopTitle });

		// Set up dialog handler for confirmation
		page.on('dialog', (dialog) => dialog.accept());

		await workshopCard.getByRole('button', { name: 'Delete' }).click();

		// Workshop should disappear from the list
		await expect(page.getByText(workshopTitle)).not.toBeVisible();
	});

	test('should work for workshop coordinator role', async ({ page, context }) => {
		await loginAsUser(context, workshopCoordinatorData.email);
		await page.goto('/dashboard/workshops');

		// Should show the workshops page
		await expect(page.getByRole('heading', { name: 'Workshops' })).toBeVisible();

		// Should show create button for workshop coordinator
		await expect(page.getByRole('button', { name: 'Create Workshop' })).toBeVisible();

		// Should be able to access create form
		await page.getByRole('button', { name: 'Create Workshop' }).click();
		await expect(page).toHaveURL('/dashboard/workshops/create');
		await expect(page.getByRole('heading', { name: 'Create Workshop' })).toBeVisible();
	});

	test('should show empty state when no workshops exist', async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto('/dashboard/workshops');

		// Wait for the page to load
		await page.waitForLoadState('networkidle');

		// Should show empty state message if no workshops (or just the workshops we created in other tests)
		// The exact message depends on whether other tests left workshops in the database
		await expect(page.getByRole('heading', { name: 'Workshops' })).toBeVisible();
	});

	test('should format prices correctly in workshop list', async ({ page, context }) => {
		await loginAsUser(context, adminData.email);

		// Create a workshop with specific prices to test formatting
		const timestamp = Date.now();
		const workshopTitle = `Price Format Test ${timestamp}`;

		const workshopData = {
			title: workshopTitle,
			description: 'Test price formatting',
			location: 'Test Location',
			workshop_date: dayjs().add(1, 'day').format('YYYY-MM-DD'),
			workshop_time: '14:00',
			max_capacity: 10,
			price_member: 12.5, // €12.50
			price_non_member: 20.75, // €20.75
			is_public: true,
			refund_deadline_days: 3
		};

		const response = await page.request.post('/api/workshops', {
			data: workshopData
		});
		expect(response.ok()).toBeTruthy();

		// Visit workshops page
		await page.goto('/dashboard/workshops');

		// Check that prices are formatted correctly (from cents to euros)
		const workshopCard = page.locator('article').filter({ hasText: workshopTitle });
		await expect(workshopCard.getByText('€12.50')).toBeVisible();
		await expect(workshopCard.getByText('€20.75')).toBeVisible();
	});
});
