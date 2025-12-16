import { expect, test } from '@playwright/test';
import { createMember, setupInvitedUser } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Invitations Manager', () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let expiredInvitation: Awaited<ReturnType<typeof setupInvitedUser>>;

	test.beforeAll(async () => {
		// Create an admin user for testing with a unique email
		const uniqueEmail = `invite-admin-${Date.now()}@test.com`;
		adminData = await createMember({
			email: uniqueEmail,
			roles: new Set(['admin'])
		});

		// Create a user with an expired invitation
		expiredInvitation = await setupInvitedUser({
			email: `expired-invite-${Date.now()}@test.com`,
			invitationStatus: 'expired'
		});
	});

	test.beforeEach(async ({ context }) => {
		// Login as admin before each test
		await loginAsUser(context, adminData.email);
	});

	test.afterAll(async () => {
		// Clean up test data
		await adminData?.cleanUp();
		await expiredInvitation?.cleanUp();
	});

	test('should display invitations tab in members page', async ({ page }) => {
		// Navigate to members page
		await page.goto('/dashboard/members');

		// Check if the invitations tab exists
		await expect(page.getByRole('tab', { name: 'Invitations' })).toBeVisible();
	});

	test('should display list of invitations', async ({ page }) => {
		// Navigate to members page
		await page.goto('/dashboard/members');

		// Click on the invitations tab
		await page.getByRole('tab', { name: 'Invitations' }).click();
		// Check if the invitations table is displayed
		await expect(page.getByRole('textbox', { name: 'Search members' })).toBeVisible();
	});

	test('should be able to resend an expired invitation link', async ({ page }) => {
		// Navigate to members page
		await page.goto('/dashboard/members');

		// Click on the invitations tab
		await page.getByRole('tab', { name: 'Invitations' }).click();

		// Search for the expired invitation
		await page.getByRole('textbox', { name: 'Search members' }).fill(expiredInvitation.email);

		// Wait for the search results
		await page.waitForTimeout(1000);

		// Check if the expired invitation is displayed
		await expect(page.getByText(expiredInvitation.email)).toBeVisible();

		// Check if the status is expired
		await expect(page.getByText('expired')).toBeVisible();

		// Click the resend link button
		await page.getByRole('button', { name: 'Resend Link' }).click();

		// Check for success message
		await expect(page.getByText('Invitation link sent')).toBeVisible();

		// Verify the invitation status has been updated (should now be pending)
		await page.waitForTimeout(1000); // Wait for the table to refresh
		await expect(page.getByText('pending')).toBeVisible();
	});

	test('should handle errors when resending invitation link', async ({ page }) => {
		// Navigate to members page
		await page.goto('/dashboard/members');

		// Click on the invitations tab
		await page.getByRole('tab', { name: 'Invitations' }).click();

		// Mock a network error for the RPC call
		await page.route('**/rest/v1/rpc/resend_invitation_link', async (route) => {
			await route.fulfill({
				status: 500,
				body: JSON.stringify({ error: 'Internal Server Error' })
			});
		});

		// Search for the expired invitation
		await page.getByRole('textbox', { name: 'Search members' }).fill(expiredInvitation.email);

		// Wait for the search results
		await page.waitForTimeout(1000);

		// Click the resend link button
		await page.getByRole('button', { name: 'Resend Link' }).click();

		// Check for error message
		await expect(page.getByText('Failed to update invitation')).toBeVisible();
	});

	test('should paginate through invitations list', async ({ page }) => {
		// Navigate to members page
		await page.goto('/dashboard/members');

		// Click on the invitations tab
		await page.getByRole('textbox', { name: 'Search members' }).click();

		// Check if pagination controls are visible
		await expect(page.getByText('Rows per page')).toBeVisible();

		// Change page size
		await page.getByRole('combobox').click();
		await page.getByRole('option', { name: '25' }).click();

		// Check if page size was updated
		await expect(page.getByText('Page 1 of')).toBeVisible();
	});

	test('should sort invitations by different columns', async ({ page }) => {
		// Navigate to members page
		await page.goto('/dashboard/members');

		// Click on the invitations tab
		await page.getByRole('textbox', { name: 'Search members' }).click();

		// Sort by email
		await page.getByRole('columnheader', { name: 'Email' }).click();

		// Check if sorting indicator is visible
		await expect(page.locator('th').filter({ hasText: 'Email' }).locator('svg')).toBeVisible();

		// Sort by created date
		await page.getByRole('columnheader', { name: 'Created' }).click();

		// Check if sorting indicator is visible
		await expect(page.locator('th').filter({ hasText: 'Created' }).locator('svg')).toBeVisible();
	});
});
