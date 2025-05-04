// playwright.test.ts
import { expect, test } from '@playwright/test';
import { faker } from '@faker-js/faker';
import dayjs from 'dayjs';
import { getSupabaseServiceClient } from './setupFunctions';

// Test data for an underage user (16-17 years old)
const underageTestData = {
	firstName: faker.person.firstName(),
	lastName: faker.person.lastName(),
	email: faker.internet.email(),
	phoneNumber: '0840997863',
	dateOfBirth: dayjs().subtract(16, 'years'), // 16 years old
	medicalConditions: faker.lorem.sentence(),
	guardianFirstName: faker.person.firstName(),
	guardianLastName: faker.person.lastName(),
	guardianPhoneNumber: '0840998877'
};

// Test data for an adult user (18+ years old)
const adultTestData = {
	firstName: faker.person.firstName(),
	lastName: faker.person.lastName(),
	email: faker.internet.email(),
	phoneNumber: '0840997863',
	dateOfBirth: dayjs().subtract(25, 'years'), // 25 years old
	medicalConditions: faker.lorem.sentence()
};

test.afterAll(async () => {
	await (
		await getSupabaseServiceClient()
	)
		.from('settings')
		.update({
			value: 'true'
		})
		.eq('key', 'waitlist_open')
		.throwOnError();
});

test('underage user (16-17) should see guardian fields', async ({ page }) => {
	// Navigate to the form page
	await page.goto('/waitlist');

	// Fill out the date of birth for an underage user
	await page.getByLabel(/date of birth/i).click();
	await page.getByLabel('Select year').click();
	await page.getByRole('option', { name: underageTestData.dateOfBirth.year().toString() }).click();
	await page.getByLabel('Select month').click();
	await page.getByRole('option', { name: underageTestData.dateOfBirth.format('MMMM') }).dblclick();
	await page.getByLabel(underageTestData.dateOfBirth.format('dddd, MMMM D,')).click();

	// Verify that guardian fields are visible
	await expect(page.getByText('Guardian Information (Required for under 18)')).toBeVisible();
	await expect(page.getByLabel('Guardian First Name')).toBeVisible();
	await expect(page.getByLabel('Guardian Last Name')).toBeVisible();
	await expect(page.getByLabel('Guardian Phone Number')).toBeVisible();
});

test('adult user (18+) should not see guardian fields', async ({ page }) => {
	// Navigate to the form page
	await page.goto('/waitlist');

	// Fill out the date of birth for an adult user
	await page.getByLabel(/date of birth/i).click();
	await page.getByLabel('Select year').click();
	await page.getByRole('option', { name: adultTestData.dateOfBirth.year().toString() }).click();
	await page.getByLabel('Select month').click();
	await page.getByRole('option', { name: adultTestData.dateOfBirth.format('MMMM') }).dblclick();
	await page.getByLabel(adultTestData.dateOfBirth.format('dddd, MMMM D,')).click();

	// Verify that guardian fields are not visible
	await expect(page.getByText('Guardian Information (Required for under 18)')).not.toBeVisible();
});

test('underage user (16-17) should be required to fill guardian fields', async ({ page }) => {
	// Navigate to the form page
	await page.goto('/waitlist');

	// Fill out the form for an underage user without guardian information
	await page.fill('input[name="firstName"]', underageTestData.firstName);
	await page.fill('input[name="lastName"]', underageTestData.lastName);
	await page.fill('input[name="email"]', underageTestData.email);

	// Find the phone input field
	const phoneInputField = page
		.locator('div')
		.filter({ hasText: /phone number/i })
		.locator('input[type="tel"]');

	await phoneInputField.pressSequentially(underageTestData.phoneNumber, { delay: 50 });
	await phoneInputField.blur();
	await page.getByPlaceholder('Enter your pronouns').fill('he/him');
	await page.getByLabel(/gender/i).click();
	await page.getByRole('option', { name: 'man (cis)', exact: true }).click();

	// Fill out the date of birth for an underage user
	await page.getByLabel(/date of birth/i).click();
	await page.getByLabel('Select year').click();
	await page.getByRole('option', { name: underageTestData.dateOfBirth.year().toString() }).click();
	await page.getByLabel('Select month').click();
	await page.getByRole('option', { name: underageTestData.dateOfBirth.format('MMMM') }).dblclick();
	await page.getByLabel(underageTestData.dateOfBirth.format('dddd, MMMM D,')).click();
	await page.getByRole('radio', { name: 'No', exact: true }).click();

	await page.getByLabel(/any medical condition/i).fill(underageTestData.medicalConditions);

	// Submit the form without filling guardian fields
	await page.click('button[type="submit"]');

	// Verify that validation errors appear for guardian fields
	await expect(page.getByText('Guardian first name is required')).toBeVisible();
	await expect(page.getByText('Guardian last name is required')).toBeVisible();
	await expect(page.getByText('Guardian phone number is required')).toBeVisible();
});

test('underage user (16-17) should be able to submit with guardian information', async ({
	page
}) => {
	// Navigate to the form page
	await page.goto('/waitlist');

	// Fill out the form for an underage user
	await page.fill('input[name="firstName"]', underageTestData.firstName);
	await page.fill('input[name="lastName"]', underageTestData.lastName);
	await page.fill('input[name="email"]', underageTestData.email);

	// Find the phone input field
	const phoneInputField = page
		.locator('div')
		.filter({ hasText: /phone number/i })
		.locator('input[type="tel"]');

	await phoneInputField.pressSequentially(underageTestData.phoneNumber, { delay: 50 });
	await phoneInputField.blur();
	await page.getByPlaceholder('Enter your pronouns').fill('he/him');
	await page.getByLabel(/gender/i).click();
	await page.getByRole('option', { name: 'man (cis)', exact: true }).click();

	// Fill out the date of birth for an underage user
	await page.getByLabel(/date of birth/i).click();
	await page.getByLabel('Select year').click();
	await page.getByRole('option', { name: underageTestData.dateOfBirth.year().toString() }).click();
	await page.getByLabel('Select month').click();
	await page.getByRole('option', { name: underageTestData.dateOfBirth.format('MMMM') }).dblclick();
	await page.getByLabel(underageTestData.dateOfBirth.format('dddd, MMMM D,')).click();
	await page.getByRole('radio', { name: 'No', exact: true }).click();

	await page.getByLabel(/any medical condition/i).fill(underageTestData.medicalConditions);

	// Fill out guardian information
	await page.fill('input[name="guardianFirstName"]', underageTestData.guardianFirstName);
	await page.fill('input[name="guardianLastName"]', underageTestData.guardianLastName);

	// Find the guardian phone input field
	const guardianPhoneInputField = page.getByLabel('Guardian Phone Number');

	await guardianPhoneInputField.pressSequentially(underageTestData.guardianPhoneNumber, {
		delay: 50
	});
	await guardianPhoneInputField.blur();

	// Submit the form
	await page.click('button[type="submit"]');

	// Verify successful submission
	await expect(
		page.getByText('You have been added to the waitlist, we will be in contact soon!')
	).toBeVisible();
});

test('adult user (18+) should be able to submit without guardian information', async ({ page }) => {
	// Navigate to the form page
	await page.goto('/waitlist');

	// Fill out the form for an adult user
	await page.fill('input[name="firstName"]', adultTestData.firstName);
	await page.fill('input[name="lastName"]', adultTestData.lastName);
	await page.fill('input[name="email"]', adultTestData.email);

	// Find the phone input field
	const phoneInputField = page
		.locator('div')
		.filter({ hasText: /phone number/i })
		.locator('input[type="tel"]');

	await phoneInputField.pressSequentially(adultTestData.phoneNumber, { delay: 50 });
	await phoneInputField.blur();
	await page.getByPlaceholder('Enter your pronouns').fill('he/him');
	await page.getByLabel(/gender/i).click();
	await page.getByRole('option', { name: 'man (cis)', exact: true }).click();

	// Fill out the date of birth for an adult user
	await page.getByLabel(/date of birth/i).click();
	await page.getByLabel('Select year').click();
	await page.getByRole('option', { name: adultTestData.dateOfBirth.year().toString() }).click();
	await page.getByLabel('Select month').click();
	await page.getByRole('option', { name: adultTestData.dateOfBirth.format('MMMM') }).dblclick();
	await page.getByLabel(adultTestData.dateOfBirth.format('dddd, MMMM D,')).click();
	await page.getByRole('radio', { name: 'No', exact: true }).click();

	await page.getByLabel(/any medical condition/i).fill(adultTestData.medicalConditions);

	// Submit the form
	await page.click('button[type="submit"]');

	// Verify successful submission
	await expect(
		page.getByText('You have been added to the waitlist, we will be in contact soon!')
	).toBeVisible();
});
