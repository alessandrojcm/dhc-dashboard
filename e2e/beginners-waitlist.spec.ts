// playwright.test.ts
import { test, expect } from '@playwright/test';
import { faker } from '@faker-js/faker';
import dayjs from 'dayjs';
import { getSupabaseServiceClient } from './setupFunctions';

const testData = {
	firstName: faker.person.firstName(),
	lastName: faker.person.lastName(),
	email: faker.internet.email(),
	phoneNumber: faker.phone.number({ style: 'international' }),
	dateOfBirth: dayjs().subtract(16, 'years'), // Ensure date format is YYYY-MM-DD
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
})

test('fills out the waitlist form and asserts no errors', async ({ page }) => {
	// Generate test data using faker-js

	// Navigate to the form page
	await page.goto('/waitlist');

	// Fill out the form
	await page.fill('input[name="firstName"]', testData.firstName);
	await page.fill('input[name="lastName"]', testData.lastName);
	await page.fill('input[name="email"]', testData.email);
	await page.getByLabel(/phone number/i).pressSequentially(testData.phoneNumber, { delay: 50 });
	await page.getByLabel(/phone number/i).blur();
	await page.getByPlaceholder('Enter your pronouns').fill('he/him');
	await page.getByLabel(/gender/i).click();
	await page.getByRole('option', { name: 'man (cis)', exact: true }).click();
	await page.getByPlaceholder('Enter your pronouns').fill('he/him');

	await page.getByLabel('Date of birth').click();
	await page.getByLabel('Select year').click();
	await page.getByRole('option', { name: testData.dateOfBirth.year().toString() }).click();
	await page.getByLabel('Select month').click();
	await page.getByRole('option', { name: testData.dateOfBirth.format('MMMM') }).dblclick();
	await page.getByLabel(testData.dateOfBirth.format('dddd, MMMM D,')).click();
	await page.getByRole('radio', { name: 'No', exact: true }).click();

	await page.getByLabel(/any medical condition/i).fill(testData.medicalConditions);
	// Submit the form
	await page.click('button[type="submit"]');
	await expect(page.getByText('You have been added to the waitlist, we will be in contact soon!')).toBeVisible();
});

test('it should not allow people under 16 to sign up', async ({ page }) => {
	// Generate test data using faker-js

	// Navigate to the form page
	await page.goto('/waitlist');
	const dateOfBirth = dayjs();
	await page.getByLabel(/date of birth/i).click();
	await page.getByLabel('Select year').click();
	await page.getByRole('option', { name: dateOfBirth.year().toString() }).click();
	await page.getByLabel('Select month').click();
	await page.getByRole('option', { name: dateOfBirth.format('MMMM') }).dblclick();
	await page.getByLabel(dateOfBirth.format('dddd, MMMM D,')).click();

	// Submit the form
	await page.click('button[type="submit"]');
	await expect(await page.getByText(/you must be at least 16 years old/i)).toBeInViewport();
});

test('it should not show the waitlist if closed', async ({ page }) => {
	await (
		await getSupabaseServiceClient()
	)
		.from('settings')
		.update({
			value: 'false'
		})
		.eq('key', 'waitlist_open')
		.throwOnError();
	// Navigate to the form page
	await page.goto('/waitlist');
	await expect(page.getByText(/the waitlist is currently closed/i)).toBeVisible();
});
