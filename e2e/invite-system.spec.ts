import { expect, test } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';
import { faker } from '@faker-js/faker/locale/en_IE';
import dayjs from 'dayjs';

test.describe('Invitation System', () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		// Create an admin user for testing with a unique email
		const uniqueEmail = `invite-admin-${Date.now()}@test.com`;
		adminData = await createMember({
			email: uniqueEmail,
			roles: new Set(['admin'])
		});
	});

	test.beforeEach(async ({ context }) => {
		// Login as admin before each test
		await loginAsUser(context, adminData.email);
	});

	test.afterAll(() => adminData?.cleanUp());

	test('should be able to add an invitation to the list and send it', async ({ page }) => {
		// Navigate to members page
		await page.goto('/dashboard/members');

		// Open invite drawer
		await page.getByRole('button', { name: 'Invite Members' }).click();

		// Fill out the invitation form
		const testEmail = `test-email-${Date.now()}@test.com`;
		const firstName = faker.person.firstName();
		const lastName = faker.person.lastName();

		await page.getByLabel('First Name').fill(firstName);
		await page.getByLabel('Last Name').fill(lastName);
		await page.getByLabel('Email').fill(testEmail);

		// Set date of birth (using the DatePicker component)
		const dateOfBirth = dayjs().subtract(25, 'year'); // 25 years ago

		// Interact with the date picker properly
		await page.getByLabel(/date of birth/i).click();
		await page.getByLabel('Select year').click();
		await page.getByRole('option', { name: dateOfBirth.year().toString() }).click();
		await page.getByLabel('Select month').click();
		await page.getByRole('option', { name: dateOfBirth.format('MMMM') }).dblclick();
		await page.getByLabel(dateOfBirth.format('dddd, MMMM D,')).click();

		// Fill phone number
		await page.getByLabel('Phone Number').fill('123456789');

		// Add to list first
		await page.getByRole('button', { name: 'Add to List' }).click();

		// Verify the invitation was added to the list
		await expect(page.getByText(testEmail)).toBeVisible();
		await expect(page.getByText('Invite List (1)')).toBeVisible();
		// Then send the invite - note that the form is now empty but that's OK
		// The "Send Invitations" button submits a different form with the invites list
		await page.pause();
		await page.getByRole('button', { name: 'Send 1 Invitations' }).click();

		// Verify success message with a longer timeout
		await expect(
			page.getByText(
				'Invitations are being processed in the background. You will be notified when completed.',
				{ exact: false }
			)
		).toBeVisible({ timeout: 10000 });
	});

	test('should validate required fields when adding to list', async ({ page }) => {
		// Navigate to members page
		await page.goto('/dashboard/members');

		// Open invite drawer
		await page.getByRole('button', { name: 'Invite Members' }).click();

		// Try to add to list without filling required fields
		await page.getByRole('button', { name: 'Add to List' }).click();

		// Verify validation errors
		await expect(page.getByText(/please enter an email/i)).toBeVisible();
		await expect(page.getByText('Phone Number is required')).toBeVisible();
	});

	test('should be able to add multiple invitations to the list and send them', async ({ page }) => {
		// Navigate to members page
		await page.goto('/dashboard/members');

		// Open invite drawer
		await page.getByRole('button', { name: 'Invite Members' }).click();

		// Add first invitation to the list
		const testEmail1 = `test-email-${Date.now()}-1@test.com`;
		await page.getByLabel('First Name').fill(faker.person.firstName());
		await page.getByLabel('Last Name').fill(faker.person.lastName());
		await page.getByLabel('Email').fill(testEmail1);

		// Set date of birth
		const dateOfBirth = dayjs().subtract(25, 'year');

		// Interact with the date picker properly
		await page.getByLabel(/date of birth/i).click();
		await page.getByLabel('Select year').click();
		await page.getByRole('option', { name: dateOfBirth.year().toString() }).click();
		await page.getByLabel('Select month').click();
		await page.getByRole('option', { name: dateOfBirth.format('MMMM') }).dblclick();
		await page.getByLabel(dateOfBirth.format('dddd, MMMM D,')).click();

		await page.getByLabel('Phone Number').fill('123456789');

		// Click "Add to List" button
		await page.getByRole('button', { name: 'Add to List' }).click();

		// Verify the invitation was added to the list
		await expect(page.getByText(testEmail1)).toBeVisible();

		// Add second invitation to the list
		const testEmail2 = `test-email-${Date.now()}-2@test.com`;
		await page.getByLabel('First Name').fill(faker.person.firstName());
		await page.getByLabel('Last Name').fill(faker.person.lastName());
		await page.getByLabel('Email').fill(testEmail2);

		// Set date of birth for second invitation
		const dateOfBirth2 = dayjs().subtract(30, 'year');

		// Interact with the date picker properly
		await page.getByLabel(/date of birth/i).click();
		await page.getByLabel('Select year').click();
		await page.getByRole('option', { name: dateOfBirth2.year().toString() }).click();
		await page.getByLabel('Select month').click();
		await page.getByRole('option', { name: dateOfBirth2.format('MMMM') }).dblclick();
		await page.getByLabel(dateOfBirth2.format('dddd, MMMM D,')).click();

		await page.getByLabel('Phone Number').fill('987654321');

		// Click "Add to List" button
		await page.getByRole('button', { name: 'Add to List' }).click();

		// Verify both invitations are in the list
		await expect(page.getByText(testEmail1)).toBeVisible();
		await expect(page.getByText(testEmail2)).toBeVisible();

		// Verify the invite count is correct
		await expect(page.getByText('Invite List (2)')).toBeVisible();

		// Submit bulk invites - this uses a separate form with just the invites list
		await page.getByRole('button', { name: 'Send 2 Invitations' }).click();

		// Verify success message with a longer timeout
		await expect(
			page.getByText(
				'Invitations are being processed in the background. You will be notified when completed.',
				{ exact: false }
			)
		).toBeVisible({ timeout: 10000 });
	});

	test('should be able to remove invitations from the list', async ({ page }) => {
		// Navigate to members page
		await page.goto('/dashboard/members');

		// Open invite drawer
		await page.getByRole('button', { name: 'Invite Members' }).click();

		// Add first invitation to the list
		const testEmail1 = `test-email-${Date.now()}-1@test.com`;
		await page.getByLabel('First Name').fill(faker.person.firstName());
		await page.getByLabel('Last Name').fill(faker.person.lastName());
		await page.getByLabel('Email').fill(testEmail1);

		// Set date of birth
		const dateOfBirth = dayjs().subtract(25, 'year');

		// Interact with the date picker properly
		await page.getByLabel(/date of birth/i).click();
		await page.getByLabel('Select year').click();
		await page.getByRole('option', { name: dateOfBirth.year().toString() }).click();
		await page.getByLabel('Select month').click();
		await page.getByRole('option', { name: dateOfBirth.format('MMMM') }).dblclick();
		await page.getByLabel(dateOfBirth.format('dddd, MMMM D,')).click();

		await page.getByLabel('Phone Number').fill('123456789');

		// Click "Add to List" button
		await page.getByRole('button', { name: 'Add to List' }).click();

		// Add second invitation to the list
		const testEmail2 = `test-email-${Date.now()}-2@test.com`;
		await page.getByLabel('First Name').fill(faker.person.firstName());
		await page.getByLabel('Last Name').fill(faker.person.lastName());
		await page.getByLabel('Email').fill(testEmail2);

		// Set date of birth for second invitation
		const dateOfBirth2 = dayjs().subtract(30, 'year');

		// Interact with the date picker properly
		await page.getByLabel(/date of birth/i).click();
		await page.getByLabel('Select year').click();
		await page.getByRole('option', { name: dateOfBirth2.year().toString() }).click();
		await page.getByLabel('Select month').click();
		await page.getByRole('option', { name: dateOfBirth2.format('MMMM') }).dblclick();
		await page.getByLabel(dateOfBirth2.format('dddd, MMMM D,')).click();
		await expect(page.getByLabel('Phone Number')).toBeVisible();
		await page.getByLabel('Phone Number').fill('987654321');

		// Click "Add to List" button
		await page.getByRole('button', { name: 'Add to List' }).click();

		// Verify both invitations are in the list
		await expect(page.getByText(testEmail1)).toBeVisible();
		await expect(page.getByText(testEmail2)).toBeVisible();
		// Remove the first invitation
		await page.getByLabel('Remove invite').first().click();

		// Verify only the second invitation remains
		await expect(page.getByText(testEmail1)).not.toBeVisible();
		await expect(page.getByText(testEmail2)).toBeVisible();

		// Verify the invite count is updated
		await expect(page.getByText('Invite List (1)')).toBeVisible();

		// Clear all invitations
		await page.getByRole('button', { name: 'Clear All' }).click();

		// Verify no invitations remain
		await expect(page.getByText('No invites added yet')).toBeVisible();
	});

	test('should validate email format when adding to list', async ({ page }) => {
		// Navigate to members page
		await page.goto('/dashboard/members');

		// Open invite drawer
		await page.getByRole('button', { name: 'Invite Members' }).click();

		// Fill out the invitation form with invalid email
		await page.getByLabel('First Name').fill(faker.person.firstName());
		await page.getByLabel('Last Name').fill(faker.person.lastName());
		await page.getByLabel('Email').fill('invalid-email');

		// Set date of birth
		const dateOfBirth = dayjs().subtract(25, 'year');

		// Interact with the date picker properly
		await page.getByLabel(/date of birth/i).click();
		await page.getByLabel('Select year').click();
		await page.getByRole('option', { name: dateOfBirth.year().toString() }).click();
		await page.getByLabel('Select month').click();
		await page.getByRole('option', { name: dateOfBirth.format('MMMM') }).dblclick();
		await page.getByLabel(dateOfBirth.format('dddd, MMMM D,')).click();

		await page.getByLabel('Phone Number').fill('123456789');

		// Try to add to list
		await page.getByRole('button', { name: 'Add to List' }).click();

		// Verify validation error
		await expect(page.getByText(/email is invalid/i)).toBeVisible();
	});

	test('should test permissions - regular member cannot invite', async ({ page, context }) => {
		// Create a regular member with unique email
		const uniqueEmail = `regular-member-${Date.now()}@test.com`;
		const memberData = await createMember({
			email: uniqueEmail,
			roles: new Set(['member'])
		});

		try {
			// Login as regular member
			await loginAsUser(context, memberData.email);

			// Navigate to members page
			await page.goto('/dashboard/members');

			// Verify the invite button is not visible
			await expect(page.getByRole('button', { name: 'Invite Members' })).not.toBeVisible();
		} finally {
			// Clean up the test member
			await memberData.cleanUp();
		}
	});

	test('should test permissions - committee coordinator can invite', async ({ page, context }) => {
		// Create a committee coordinator with unique email
		const uniqueEmail = `coordinator-${Date.now()}@test.com`;
		const coordinatorData = await createMember({
			email: uniqueEmail,
			roles: new Set(['committee_coordinator'])
		});

		try {
			// Login as committee coordinator
			await loginAsUser(context, coordinatorData.email);

			// Navigate to members page
			await page.goto('/dashboard/members');

			// Verify the invite button is visible
			await expect(page.getByRole('button', { name: 'Invite Members' })).toBeVisible();

			// Test basic invite functionality
			await page.getByRole('button', { name: 'Invite Members' }).click();

			// Fill out the invitation form
			const testEmail = `test-email-${Date.now()}@test.com`;
			await page.getByLabel('First Name').fill(faker.person.firstName());
			await page.getByLabel('Last Name').fill(faker.person.lastName());
			await page.getByLabel('Email').fill(testEmail);

			// Set date of birth
			const dateOfBirth = dayjs().subtract(25, 'year');

			// Interact with the date picker properly
			await page.getByLabel(/date of birth/i).click();
			await page.getByLabel('Select year').click();
			await page.getByRole('option', { name: dateOfBirth.year().toString() }).click();
			await page.getByLabel('Select month').click();
			await page.getByRole('option', { name: dateOfBirth.format('MMMM') }).dblclick();
			await page.getByLabel(dateOfBirth.format('dddd, MMMM D,')).click();

			await page.getByLabel('Phone Number').fill('123456789');

			// Click "Add to List" button
			await page.getByRole('button', { name: 'Add to List' }).click();

			// Verify the invitation was added to the list
			await expect(page.getByText(testEmail)).toBeVisible();
		} finally {
			// Clean up the test coordinator
			await coordinatorData.cleanUp();
		}
	});
});
