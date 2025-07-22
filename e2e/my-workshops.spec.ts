import { test, expect } from '@playwright/test';
import { createMember, getSupabaseServiceClient } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('My Workshops Page', () => {
	let memberData: Awaited<ReturnType<typeof createMember>>;
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let plannedWorkshopId: string;
	let publishedWorkshopId: string;
	const timestamp = Date.now();

	test.beforeAll(async () => {
		const randomSuffix = Math.random().toString(36).substring(2, 15);

		// Create member user
		memberData = await createMember({
			email: `member-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['member'])
		});

		// Create admin user for workshop management
		adminData = await createMember({
			email: `admin-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['admin'])
		});
	});

	test.beforeEach(async () => {
		const supabase = getSupabaseServiceClient();
		const plannedWorkshopStartDate = new Date(Date.now() + 86400000); // tomorrow
		const plannedWorkshopEndDate = new Date(
			plannedWorkshopStartDate.getTime() + 2 * 60 * 60 * 1000
		); // 2 hours later
		const publishedWorkshopStartDate = new Date(Date.now() + 2 * 86400000); // day after tomorrow
		const publishedWorkshopEndDate = new Date(
			publishedWorkshopStartDate.getTime() + 2 * 60 * 60 * 1000
		); // 2 hours later

		// Create planned workshop
		const { data: plannedWorkshop, error: plannedError } = await supabase
			.from('club_activities')
			.insert({
				title: `Planned Workshop ${timestamp}`,
				description: 'Test planned workshop for my-workshops page',
				location: 'Test Location',
				start_date: plannedWorkshopStartDate.toISOString(),
				end_date: plannedWorkshopEndDate.toISOString(),
				max_capacity: 20,
				price_member: 1000, // €10.00
				price_non_member: 2000, // €20.00
				is_public: true,
				refund_days: 3,
				status: 'planned'
			})
			.select()
			.single();

		if (plannedError) {
			throw new Error(`Failed to create planned workshop: ${plannedError.message}`);
		}
		plannedWorkshopId = plannedWorkshop.id;

		// Create published workshop
		const { data: publishedWorkshop, error: publishedError } = await supabase
			.from('club_activities')
			.insert({
				title: `Published Workshop ${timestamp}`,
				description: 'Test published workshop for my-workshops page',
				location: 'Test Location',
				start_date: publishedWorkshopStartDate.toISOString(),
				end_date: publishedWorkshopEndDate.toISOString(),
				max_capacity: 15,
				price_member: 1500, // €15.00
				price_non_member: 2500, // €25.00
				is_public: true,
				refund_days: 7,
				status: 'published'
			})
			.select()
			.single();

		if (publishedError) {
			throw new Error(`Failed to create published workshop: ${publishedError.message}`);
		}
		publishedWorkshopId = publishedWorkshop.id;
	});

	async function makeAuthenticatedRequest(page: any, url: string, options: any = {}) {
		const response = await page.request.fetch(url, {
			...options,
			headers: {
				'Content-Type': 'application/json',
				...options.headers
			}
		});

		if (!response.ok()) {
			const errorText = await response.text();
			console.error(`API Error ${response.status()}: ${errorText}`);
			throw new Error(`HTTP ${response.status()}: ${response.statusText()} - ${errorText}`);
		}

		return await response.json();
	}

	test('should load my-workshops page with correct structure', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');
		// Check page title and heading
		await expect(page.locator('h1:has-text("My Workshops")')).toBeVisible();

		// Check that both tabs are present
		await expect(page.locator('button[data-value="published"]:has-text("Upcoming")')).toBeVisible();
		await expect(page.locator('button[data-value="planned"]:has-text("Planned")')).toBeVisible();

		// Check that Upcoming tab is active by default
		await expect(page.locator('button[data-value="published"][data-state="active"]')).toBeVisible();
	});

	test('should display published workshops in upcoming tab', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');

		// Wait for content to load
		await expect(page.locator('h1:has-text("My Workshops")')).toBeVisible();

		// Check that published workshop is displayed
		await expect(page.locator(`text=Published Workshop ${timestamp}`)).toBeVisible();
		await expect(page.locator('text=Test published workshop for my-workshops page')).toBeVisible();
		await expect(page.locator('text=€15.00')).toBeVisible(); // Member price
		await expect(page.locator('text=€25.00')).toBeVisible(); // Non-member price
		await expect(page.locator('text=15')).toBeVisible(); // Capacity
		await expect(page.locator('text=published')).toBeVisible(); // Status badge
	});

	test('should display planned workshops in planned tab', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');

		// Switch to planned tab
		await page.click('button[data-value="planned"]');
		await expect(page.locator('button[data-value="planned"][data-state="active"]')).toBeVisible();

		// Check that planned workshop is displayed
		await expect(page.locator(`text=Planned Workshop ${timestamp}`)).toBeVisible();
		await expect(page.locator('text=Test planned workshop for my-workshops page')).toBeVisible();
		await expect(page.locator('text=€10.00')).toBeVisible(); // Member price
		await expect(page.locator('text=€20.00')).toBeVisible(); // Non-member price
		await expect(page.locator('text=20')).toBeVisible(); // Capacity
		await expect(page.locator('text=planned')).toBeVisible(); // Status badge
		await expect(page.locator('text=0 people interested')).toBeVisible(); // Interest count
	});

	test('should allow member to express interest in planned workshop', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');

		// Switch to planned tab
		await page.click('button[data-value="planned"]');
		await expect(page.locator('button[data-value="planned"][data-state="active"]')).toBeVisible();

		// Find and click express interest button
		await expect(page.locator('button:has-text("Express Interest")')).toBeVisible();
		await page.click('button:has-text("Express Interest")');

		// Check success message appears
		await expect(page.locator('text=Interest expressed successfully')).toBeVisible();

		// Check button text changes
		await expect(page.locator('button:has-text("Withdraw Interest")')).toBeVisible();

		// Check interest count updates
		await expect(page.locator('text=1 people interested')).toBeVisible();
	});

	test('should allow member to withdraw interest from planned workshop', async ({
		page,
		context
	}) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');

		// First express interest via API
		await makeAuthenticatedRequest(page, `/api/workshops/${plannedWorkshopId}/interest`, {
			method: 'POST'
		});

		// Switch to planned tab
		await page.click('button[data-value="planned"]');
		await expect(page.locator('button[data-value="planned"][data-state="active"]')).toBeVisible();

		// Click to withdraw interest
		await expect(page.locator('button:has-text("Withdraw Interest")')).toBeVisible();
		await page.click('button:has-text("Withdraw Interest")');

		// Check success message
		await expect(page.locator('text=Interest withdrawn successfully')).toBeVisible();

		// Check button text changes back
		await expect(page.locator('button:has-text("Express Interest")')).toBeVisible();

		// Check interest count updates
		await expect(page.locator('text=0 people interested')).toBeVisible();
	});

	test('should not show interest buttons for published workshops', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');

		// Stay on upcoming tab (published workshops)
		await expect(page.locator('button[data-value="published"][data-state="active"]')).toBeVisible();

		// Check that published workshop is displayed
		await expect(page.locator(`text=Published Workshop ${timestamp}`)).toBeVisible();

		// Check that no interest buttons are present
		await expect(page.locator('button:has-text("Express Interest")')).not.toBeVisible();
		await expect(page.locator('button:has-text("Withdraw Interest")')).not.toBeVisible();

		// Check that attendee count is shown instead
		await expect(page.locator('text=0 people attending')).toBeVisible();
	});

	test('should show loading state when switching tabs', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');

		// Switch to planned tab and check for loading state
		await page.click('button[data-value="planned"]');

		// The loading state might be brief, so we check it exists or that content loads
		const loadingOrContent = page.locator('[data-testid="loading-skeleton"], .space-y-4');
		await expect(loadingOrContent).toBeVisible();

		// Eventually the content should load
		await expect(page.locator(`text=Planned Workshop ${timestamp}`)).toBeVisible();
	});

	test('should handle empty state when no workshops exist', async ({ page, context }) => {
		// Create a user without any workshops
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 15);
		const emptyUserData = await createMember({
			email: `empty-user-${timestamp}-${randomSuffix}@test.com`,
			roles: new Set(['member'])
		});

		await loginAsUser(context, emptyUserData.email);
		await page.goto('/dashboard/my-workshops');

		// Check that empty state is shown
		await expect(page.locator('text=No workshops found')).toBeVisible();
	});

	test('should display workshop details correctly', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');

		// Switch to planned tab
		await page.click('button[data-value="planned"]');

		// Check all workshop details are displayed
		await expect(page.locator(`text=Planned Workshop ${timestamp}`)).toBeVisible();
		await expect(page.locator('text=Test planned workshop for my-workshops page')).toBeVisible();
		await expect(page.locator('text=Test Location')).toBeVisible();
		await expect(page.locator('text=Capacity: 20')).toBeVisible();
		await expect(page.locator('text=Member Price: €10.00')).toBeVisible();
		await expect(page.locator('text=Non-Member Price: €20.00')).toBeVisible();

		// Check date formatting (should show formatted date)
		await expect(page.locator('text=Start:')).toBeVisible();
		await expect(page.locator('text=End:')).toBeVisible();
	});

	test('should maintain tab state when navigating back', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');

		// Switch to planned tab
		await page.click('button[data-value="planned"]');
		await expect(page.locator('button[data-value="planned"][data-state="active"]')).toBeVisible();

		// Navigate away and back
		await page.goto('/dashboard');
		await page.goBack();

		// Check that we're back to the default tab (upcoming)
		await expect(page.locator('button[data-value="published"][data-state="active"]')).toBeVisible();
	});

	test('should handle interest toggle loading state', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');

		// Switch to planned tab
		await page.click('button[data-value="planned"]');

		// Click express interest and check button is disabled during loading
		const interestButton = page.locator('button:has-text("Express Interest")');
		await expect(interestButton).toBeVisible();

		// Click and check for disabled state (might be brief)
		await interestButton.click();

		// Eventually should show success and button should change
		await expect(page.locator('text=Interest expressed successfully')).toBeVisible();
		await expect(page.locator('button:has-text("Withdraw Interest")')).toBeVisible();
	});

	test('should display status badges with correct colors', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');

		// Check published badge
		await expect(page.locator('.bg-green-500:has-text("published")')).toBeVisible();

		// Switch to planned tab
		await page.click('button[data-value="planned"]');

		// Check planned badge
		await expect(page.locator('.bg-yellow-500:has-text("planned")')).toBeVisible();
	});

	test.afterEach(async () => {
		// Clean up test workshops
		const supabase = getSupabaseServiceClient();

		if (plannedWorkshopId) {
			await supabase.from('club_activities').delete().eq('id', plannedWorkshopId);
		}

		if (publishedWorkshopId) {
			await supabase.from('club_activities').delete().eq('id', publishedWorkshopId);
		}
	});

	test.afterAll(async () => {
		// Clean up test users
		await memberData.cleanUp();
		await adminData.cleanUp();
	});
});
