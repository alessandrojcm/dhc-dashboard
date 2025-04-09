import { expect, test } from '@playwright/test';
import 'dotenv/config';
import { setupInvitedUser, stripeClient } from './setupFunctions';
import { ANNUAL_FEE_LOOKUP, MEMBERSHIP_FEE_LOOKUP_NAME } from '../src/lib/server/constants';

test.describe('Member Signup - Coupon Codes', () => {
	// Test data generated once for all tests
	let testData: Awaited<ReturnType<typeof setupInvitedUser>>;
	// Coupon codes for testing
	let annualCouponCode: string;
	let monthlyCouponCode: string;
	let combinedCouponCode: string;
	// Promotion code IDs for cleanup
	let promotionCodeIds: string[] = [];

	test.beforeAll(async () => {
		testData = await setupInvitedUser();

		// Get the price IDs for the membership fees
		const [annualPrices, monthlyPrices] = await Promise.all([
			stripeClient.prices.list({
				lookup_keys: [ANNUAL_FEE_LOOKUP]
			}),
			stripeClient.prices.list({
				lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME]
			})
		]);

		const annualPriceId = annualPrices.data[0]?.id;
		const monthlyPriceId = monthlyPrices.data[0]?.id;

		if (!annualPriceId || !monthlyPriceId) {
			throw new Error('Could not find price IDs for membership fees');
		}

		// Create coupons in Stripe
		const [annualCoupon, monthlyCoupon, combinedCoupon] = await Promise.all([
			// Coupon for annual fee only - 20% off
			stripeClient.coupons.create({
				percent_off: 20,
				duration: 'once',
				name: 'Annual Fee Test Discount',
				applies_to: {
					products: [annualPrices.data[0].product as string]
				}
			}),
			// Coupon for monthly fee only - 15% off
			stripeClient.coupons.create({
				percent_off: 15,
				duration: 'once',
				name: 'Monthly Fee Test Discount',
				applies_to: {
					products: [monthlyPrices.data[0].product as string]
				}
			}),
			// Coupon for both fees - 10% off
			stripeClient.coupons.create({
				percent_off: 10,
				duration: 'once',
				name: 'Combined Test Discount'
			})
		]);

		// Create promotion codes for the coupons
		const [annualPromotion, monthlyPromotion, combinedPromotion] = await Promise.all([
			stripeClient.promotionCodes.create({
				coupon: annualCoupon.id,
				code: `ANNUAL-${Date.now().toString().slice(-6)}`,
				max_redemptions: 5
			}),
			stripeClient.promotionCodes.create({
				coupon: monthlyCoupon.id,
				code: `MONTHLY-${Date.now().toString().slice(-6)}`,
				max_redemptions: 5
			}),
			stripeClient.promotionCodes.create({
				coupon: combinedCoupon.id,
				code: `COMBINED-${Date.now().toString().slice(-6)}`,
				max_redemptions: 5
			})
		]);

		// Save promotion codes for tests
		annualCouponCode = annualPromotion.code;
		monthlyCouponCode = monthlyPromotion.code;
		combinedCouponCode = combinedPromotion.code;

		// Save promotion code IDs for cleanup
		promotionCodeIds = [annualPromotion.id, monthlyPromotion.id, combinedPromotion.id];
	});

	test.afterAll(async () => {
		// Clean up promotion codes and coupons
		for (const promotionId of promotionCodeIds) {
			try {
				const promotion = await stripeClient.promotionCodes.retrieve(promotionId);
				await stripeClient.promotionCodes.update(promotionId, { active: false });

				// Also clean up the associated coupon
				if (promotion.coupon) {
					await stripeClient.coupons.del(promotion.coupon.id);
				}
			} catch (error) {
				console.error(`Error cleaning up promotion code ${promotionId}:`, error);
			}
		}

		// Clean up test data
		await testData.cleanUp();
	});

	test.beforeEach(async ({ page }) => {
		// Start from the signup page
		await page.goto('/members/signup/callback#access_token=' + testData.token);
		await page.waitForURL('/members/signup');
		// Wait for the form to be visible
		await page.waitForSelector('form');
	});

	test('should apply valid annual coupon code', async ({ page }) => {
		// Find and click the accordion trigger for promotional code
		await page.getByText('Have a promotional code?').click();

		// Fill in the coupon code
		await page.getByPlaceholder('Enter promotional code').fill(annualCouponCode);
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Wait for the API call to complete and prices to update
		await page.waitForTimeout(1000);

		await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({ timeout: 1000 });
		await expect(page.getByText(`Code ${annualCouponCode} applied`)).toBeVisible({ timeout: 1000 });
		// Refresh the pricing data to verify it's updated
		await page.reload();
		await page.waitForSelector('form');
	});

	test('should apply valid monthly coupon code', async ({ page }) => {
		// Find and click the accordion trigger for promotional code
		await page.getByText('Have a promotional code?').click();

		// Fill in the coupon code
		await page.getByPlaceholder('Enter promotional code').fill(monthlyCouponCode);
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Wait for the API call to complete and prices to update
		await page.waitForTimeout(1000);

		await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({ timeout: 1000 });
		await expect(page.getByText(`Code ${monthlyCouponCode} applied`)).toBeVisible({ timeout: 1000 });

		// Refresh the pricing data to verify it's updated
		await page.reload();
		await page.waitForSelector('form');
	});

	test('should apply valid combined coupon code', async ({ page }) => {
		// Find and click the accordion trigger for promotional code
		await page.getByText('Have a promotional code?').click();

		// Fill in the coupon code
		await page.getByPlaceholder('Enter promotional code').fill(combinedCouponCode);
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Wait for the API call to complete and prices to update
		await page.waitForTimeout(1000);

		await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({ timeout: 1000 });
		await expect(page.getByText(`Code ${combinedCouponCode} applied`)).toBeVisible({ timeout: 1000 });

		// Refresh the pricing data to verify it's updated
		await page.reload();
		await page.waitForSelector('form');
	});

	test('should reject invalid coupon codes', async ({ page }) => {
		// Find and click the accordion trigger for promotional code
		await page.getByText('Have a promotional code?').click();

		// Test with an invalid coupon code
		await page.getByPlaceholder('Enter promotional code').fill('INVALID-COUPON-12345');
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Verify error message
		await expect(page.getByText('Coupon code not valid')).toBeVisible({ timeout: 5000 });

		// Test with another invalid format
		await page.getByPlaceholder('Enter promotional code').fill('TEST123');
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Verify error message
		await expect(page.getByText(/coupon code not valid/i)).toBeVisible({ timeout: 5000 });

		// Test with an expired code (we can simulate this by using a non-existent code)
		await page.getByPlaceholder('Enter promotional code').fill('EXPIRED-00000');
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Verify error message
		await expect(page.getByText(/coupon code not valid/i)).toBeVisible({ timeout: 5000 });
	});
});
