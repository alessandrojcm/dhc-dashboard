// playwright.test.ts
import { test, expect } from '@playwright/test';
import { faker } from '@faker-js/faker';
import dayjs from 'dayjs';

test('fills out the waitlist form and asserts no errors', async ({ page }) => {
	// Generate test data using faker-js
	const testData = {
		firstName: faker.person.firstName(),
		lastName: faker.person.lastName(),
		email: faker.internet.email(),
		phoneNumber: faker.phone.number(),
		dateOfBirth: dayjs(faker.date.past({ years: 20 })), // Ensure date format is YYYY-MM-DD
		medicalConditions: faker.lorem.sentence()
	};

	// Navigate to the form page
	await page.goto('/public/waitlist');

	// Fill out the form
	await page.fill('input[name="firstName"]', testData.firstName);
	await page.fill('input[name="lastName"]', testData.lastName);
	await page.fill('input[name="email"]', testData.email);
	await page.fill('input[name="phoneNumber"]', testData.phoneNumber);

	await page.getByRole('button', { name: 'Select a date' }).click();
	await page.getByLabel('Select year').click();
	await page.getByRole('option', { name: testData.dateOfBirth.year().toString() }).click();
	await page.getByLabel('Select month').click();
	await page.getByRole('option', { name: testData.dateOfBirth.format('MMMM') }).click();
	await page.getByLabel(testData.dateOfBirth.format('dddd, MMMM D')).click();

	await page.fill('input[name="medicalConditions"]', testData.medicalConditions);

	// Submit the form
	await page.click('button[type="submit"]');
	const invalidFields = await page.getByText(/required/i).all();
	expect(invalidFields.length).toBe(0);
});
