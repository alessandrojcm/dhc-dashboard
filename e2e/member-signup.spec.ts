import { test, expect } from '@playwright/test';
import { faker } from '@faker-js/faker/locale/en_IE';
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import type { Database } from '../src/database.types';

function getSupabaseServiceClient() {
	const supabaseUrl = process.env.PUBLIC_SUPABASE_URL;
	const serviceRoleKey = process.env.SERVICE_ROLE_KEY;
	if (!supabaseUrl || !serviceRoleKey) {
		throw new Error('Missing SUPABASE_URL or SERVICE_ROLE_KEY in environment variables');
	}
	return createClient<Database>(supabaseUrl, serviceRoleKey);
}

async function setupUser(
	{
		addWaitlist = true,
		addSupabaseId = true,
		setWaitlistNotCompleted = false
	}: { addWaitlist: boolean; addSupabaseId: boolean; setWaitlistNotCompleted: boolean } = {
		addWaitlist: true,
		addSupabaseId: true,
		setWaitlistNotCompleted: false
	}
) {
	const supabaseServiceClient = getSupabaseServiceClient();
	const testData = {
		first_name: faker.person.firstName(),
		last_name: faker.person.lastName(),
		email: faker.internet.email().toLowerCase(),
		date_of_birth: faker.date.birthdate({ min: 16, max: 65, mode: 'age' }),
		pronouns: faker.helpers.arrayElement(['he/him', 'she/her', 'they/them']),
		gender: faker.helpers.arrayElement([
			'man (cis)',
			'woman (cis)',
			'non-binary'
		] as Database['public']['Enums']['gender'][]),
		weapon: faker.helpers.arrayElement(['longsword', 'rapier', 'sabre']),
		phone_number: faker.phone.number({ style: 'international' }),
		next_of_kin: {
			name: faker.person.fullName(),
			phone_number: faker.phone.number({ style: 'international' })
		},
		medical_conditions: faker.helpers.arrayElement(['None', 'Asthma', 'Previous knee injury'])
	};
	const waitlisEntry = await supabaseServiceClient
		.rpc('insert_waitlist_entry', {
			first_name: testData.first_name,
			last_name: testData.last_name,
			email: testData.email,
			date_of_birth: testData.date_of_birth.toISOString(),
			phone_number: testData.phone_number,
			pronouns: testData.pronouns,
			gender: testData.gender as Database['public']['Enums']['gender'],
			medical_conditions: testData.medical_conditions
		})
		.single();
	if (waitlisEntry.error) {
		throw new Error(waitlisEntry.error.message);
	}
	const inviteLink = await supabaseServiceClient.auth.admin.generateLink({
		type: 'invite',
		email: testData.email
	});
	if (inviteLink.error) {
		throw new Error(inviteLink.error.message);
	}

	await supabaseServiceClient
		.from('user_profiles')
		.update({
			supabase_user_id: addSupabaseId ? inviteLink.data.user.id : null,
			waitlist_id: addWaitlist ? waitlisEntry.data.waitlist_id : null
		})
		.eq('id', waitlisEntry.data.profile_id)
		.select()
		.throwOnError();

	await supabaseServiceClient
		.from('waitlist')
		.update({
			status: setWaitlistNotCompleted ? 'cancelled' : 'completed'
		})
		.eq('email', testData.email)
		.throwOnError();
	const verifyOtp = await supabaseServiceClient.auth.verifyOtp({
		token_hash: inviteLink.data.properties.hashed_token,
		type: 'invite'
	});
	if (verifyOtp.error) {
		throw new Error(verifyOtp.error.message);
	}
	await supabaseServiceClient.auth.signOut();
	function cleanUp() {
		// We need to create another client because when we use verifyOtp, we are effectively
		// logging as the user we are verifying the token for, hence we lose the service role privileges
		const client = getSupabaseServiceClient();
		return Promise.all([
			client.from('user_profiles').delete().eq('id', waitlisEntry?.data?.profile_id).throwOnError(),
			client.auth.admin.deleteUser(inviteLink.data.user?.id)
		]);
	}
	return Promise.resolve({
		...testData,
		waitlistId: waitlisEntry.data.waitlist_id,
		profileId: waitlisEntry.data.profile_id,
		token: verifyOtp.data.session?.access_token,
		cleanUp
	});
}

test.describe('Member Signup - Negative test cases', () => {
	[
		{
			addWaitlist: false,
			addSupabaseId: true
		},
		{
			addWaitlist: true,
			addSupabaseId: false
		},
		{
			addWaitlist: true,
			addSupabaseId: true,
			token: 'invalid_token'
		},
		{
			addWaitlist: true,
			addSupabaseId: true,
			setWaitlistNotCompleted: true
		}
	].forEach((override) => {
		let testData: Awaited<ReturnType<typeof setupUser>>;
		test.beforeAll(async () => {
			testData = await setupUser(override);
		});
		// test.afterAll(() => testData.cleanUp());

		test(`should show correct error page when the waitlist entry is wrong ${JSON.stringify(override)}`, async ({
			page
		}) => {
			await page.goto(
				'/members/signup?access_token=' +
					(override?.token !== undefined ? override.token : testData.token)
			);
			await expect(page.getByText('Something has gone wrong')).toBeVisible();
		});
	});
});
test.describe('Member Signup - Correct token', () => {
	// Test data generated once for all tests
	let testData: Awaited<ReturnType<typeof setupUser>>;

	test.beforeAll(async () => {
		testData = await setupUser();
	});

	test.beforeEach(async ({ page }) => {
		// Start from the signup page
		await page.goto('/members/signup?access_token=' + testData.token);
		// Wait for the form to be visible
		await page.waitForSelector('form');
	});

	// test.afterAll(async () => {
	// 	await testData.cleanUp();
	// });

	test('should show all required form steps', async ({ page }) => {
		await expect(page.getByText(/join dublin hema club/i)).toBeVisible();
		await expect(page.getByText('First Name')).toBeVisible();
		await expect(page.getByText('Last Name')).toBeVisible();
		await expect(page.getByText('Email')).toBeVisible();
		await expect(page.getByText('Date of Birth')).toBeVisible();

		await expect(page.getByLabel('Phone Number')).toBeVisible();
		await expect(page.getByLabel('Next of Kin', { exact: true })).toBeVisible();
		await expect(page.getByLabel('Next of Kin Phone Number')).toBeVisible();

		await expect(page.getByText('Medical Conditions')).toBeVisible();
		await expect(page.getByLabel(/insurance form/)).toBeVisible();
	});

	test('should validate required fields', async ({ page }) => {
		// Try to proceed without filling required fields
		await page.getByRole('button', { name: 'Complete Sign Up' }).click();
		// Check for validation messages
		await expect(page.getByText('Please enter your next of kin.')).toBeVisible();
		await expect(page.getByText('Phone number of your next of kin is required.')).toBeVisible();
	});

	test('should format phone numbers correctly', async ({ page }) => {
		// Test phone number formatting for both fields
		const raw_phone_number = '0838774532';
		const expected_format = '083 877 4532';

		await page
			.getByLabel('Next of Kin Phone Number')
			.pressSequentially(raw_phone_number, { delay: 50 });
		await page.locator('input[name="nextOfKinNumber"]').press('Tab');
		await expect(page.getByLabel('Next of Kin Phone Number')).toHaveValue(expected_format);
	});
});
