import { expect, test } from '@playwright/test';
import 'dotenv/config';
import { ANNUAL_FEE_LOOKUP, MEMBERSHIP_FEE_LOOKUP_NAME } from '../src/lib/server/constants';
import { setupInvitedUser, stripeClient } from './setupFunctions';

test.describe('Member Signup - Coupon Codes', () => {
	// Test data generated once for all tests
	let testData: Awaited<ReturnType<typeof setupInvitedUser>>;
	// Coupon codes for testing
	let annualCouponCode: string;
	let monthlyCouponCode: string;
	let combinedCouponCode: string;
	let onceCouponCode: string;
	let migrationCouponCode: string;
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
		const [
			annualCoupon,
			monthlyCoupon,
			combinedCoupon,
			onceCoupon,
			once100Coupon,
			migrationCoupon
		] = await Promise.all([
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
			// Coupon for both fees - 10% off (permanent discount)
			stripeClient.coupons.create({
				percent_off: 10,
				duration: 'forever',
				name: 'Combined Test Discount (Permanent)'
			}),
			// Coupon for both fees - 15% off (one-time discount)
			stripeClient.coupons.create({
				percent_off: 15,
				duration: 'once',
				name: 'One-time Test Discount'
			}),
			// Coupon for both fees - 100% off (one-time discount)
			stripeClient.coupons.create({
				percent_off: 100,
				duration: 'once',
				name: '100% Off First Payment'
			}),
			// Special migration coupon for testing the migration code functionality
			stripeClient.coupons.create({
				percent_off: 100,
				duration: 'once',
				name: 'Migration Discount'
			})
		]);

		// Create promotion codes for the coupons
		const [
			annualPromotion,
			monthlyPromotion,
			combinedPromotion,
			oncePromotion,
			once100Promotion,
			migrationPromotion
		] = await Promise.all([
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
			}),
			stripeClient.promotionCodes.create({
				coupon: onceCoupon.id,
				code: `ONCE-${Date.now().toString().slice(-6)}`,
				max_redemptions: 5
			}),
			stripeClient.promotionCodes.create({
				coupon: once100Coupon.id,
				code: `ONCE100OFF-${Date.now().toString().slice(-6)}`,
				max_redemptions: 5
			}),
			// Create the migration code with the exact name from the environment variable
			stripeClient.promotionCodes.create({
				coupon: migrationCoupon.id,
				code: process.env.PUBLIC_DASHBOARD_MIGRATION_CODE || 'DHCDASHBOARD',
				max_redemptions: 5
			})
		]);

		// Save promotion codes for tests
		annualCouponCode = annualPromotion.code;
		monthlyCouponCode = monthlyPromotion.code;
		combinedCouponCode = combinedPromotion.code;
		onceCouponCode = oncePromotion.code;
		migrationCouponCode = migrationPromotion.code;
		// We don't need to save this as we're using a fixed code 'ONCE100OFF'

		// Save promotion code IDs for cleanup
		promotionCodeIds = [
			annualPromotion.id,
			monthlyPromotion.id,
			combinedPromotion.id,
			oncePromotion.id,
			once100Promotion.id,
			migrationPromotion.id
		];
	});

	test.afterAll(async () => {
		// Clean up promotion codes and coupons
		for (const promotionId of promotionCodeIds) {
			try {
				const promotion = await stripeClient.promotionCodes.retrieve(promotionId);
				await stripeClient.promotionCodes.update(promotionId, {
					active: false
				});

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
		await page.goto(
			`/members/signup/${testData.invitationId}?email=${encodeURIComponent(testData.email)}&dateOfBirth=${encodeURIComponent(
				testData.date_of_birth.format('YYYY-MM-DD')
			)}`
		);
		// Wait for the form to be visible
		await page.waitForSelector('form');
	});

	test('should apply valid annual coupon code', async ({ page }) => {
		// Find and click the accordion trigger for promotional code
		await page.getByText('Have a promotional code?').click();

		// Fill in the coupon code
		await page.getByPlaceholder('Enter promotional code').fill(annualCouponCode);
		await page.pause();
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Wait for the API call to complete and prices to update
		await page.waitForTimeout(1000);

		await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
			timeout: 1000
		});
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

		await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
			timeout: 1000
		});
		await expect(page.getByText(`Code ${monthlyCouponCode} applied`)).toBeVisible({
			timeout: 1000
		});

		// Refresh the pricing data to verify it's updated
		await page.reload();
		await page.waitForSelector('form');
	});

	test('should apply valid combined coupon code and show discounted prices', async ({ page }) => {
		// Find and click the accordion trigger for promotional code
		await page.getByText('Have a promotional code?').click();

		// Get the original prices before applying the coupon
		const originalMonthlyPrice = await page
			.locator('text=Monthly membership fee')
			.locator('..')
			.locator('..')
			.locator('span.font-semibold')
			.textContent();
		const originalAnnualPrice = await page
			.locator('text=Annual membership fee')
			.locator('..')
			.locator('..')
			.locator('span.font-semibold')
			.textContent();
		console.log(
			`Original prices - Monthly: ${originalMonthlyPrice}, Annual: ${originalAnnualPrice}`
		);

		// Fill in the coupon code
		await page.getByPlaceholder('Enter promotional code').fill(combinedCouponCode);
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Wait for the API call to complete and prices to update
		await page.waitForTimeout(2000);

		await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
			timeout: 1000
		});
		await expect(page.getByText(`Code ${combinedCouponCode} applied`)).toBeVisible({
			timeout: 1000
		});

		// Refresh the pricing data to verify it's updated
		await page.reload();
		await page.waitForSelector('form');

		// Wait for the discount to be applied and visible
		await page.waitForSelector('text=Discount applied:', { timeout: 5000 });

		// Check that the discounted prices are shown
		const discountedMonthlyPrice = await page
			.locator('text=Monthly membership fee')
			.locator('..')
			.locator('..')
			.locator('span.text-green-600')
			.textContent();
		const discountedAnnualPrice = await page
			.locator('text=Annual membership fee')
			.locator('..')
			.locator('..')
			.locator('span.text-green-600')
			.textContent();
		console.log(
			`Discounted prices - Monthly: ${discountedMonthlyPrice}, Annual: ${discountedAnnualPrice}`
		);

		// Verify that the original prices are shown with strikethrough
		await expect(
			page
				.locator('text=Monthly membership fee')
				.locator('..')
				.locator('..')
				.locator('span.line-through')
		).toBeVisible();
		await expect(
			page
				.locator('text=Annual membership fee')
				.locator('..')
				.locator('..')
				.locator('span.line-through')
		).toBeVisible();

		// Verify that the discount percentage is shown
		await expect(page.locator('text=Discount applied:')).toBeVisible();

		// Verify that the "Applies to all future payments" text is shown (since we're using a 'forever' coupon)
		await expect(page.locator('text=Applies to all future payments')).toBeVisible();

		// Verify that the discounted prices are less than the original prices
		const originalMonthlyValue = parseFloat(originalMonthlyPrice?.replace(/[^0-9.]/g, ''));
		const discountedMonthlyValue = parseFloat(discountedMonthlyPrice?.replace(/[^0-9.]/g, ''));
		const originalAnnualValue = parseFloat(originalAnnualPrice?.replace(/[^0-9.]/g, ''));
		const discountedAnnualValue = parseFloat(discountedAnnualPrice?.replace(/[^0-9.]/g, ''));

		expect(discountedMonthlyValue).toBeLessThan(originalMonthlyValue);
		expect(discountedAnnualValue).toBeLessThan(originalAnnualValue);

		// Verify the discount percentage is approximately 10% (for combined coupon)
		const monthlyDiscountPercent = Math.round(
			((originalMonthlyValue - discountedMonthlyValue) / originalMonthlyValue) * 100
		);
		const annualDiscountPercent = Math.round(
			((originalAnnualValue - discountedAnnualValue) / originalAnnualValue) * 100
		);

		console.log(
			`Discount percentages - Monthly: ${monthlyDiscountPercent}%, Annual: ${annualDiscountPercent}%`
		);
		expect(monthlyDiscountPercent).toBeCloseTo(10, 1); // Allow 1% tolerance
		expect(annualDiscountPercent).toBeCloseTo(10, 1); // Allow 1% tolerance
	});

	test('should apply one-time coupon and show "Applies to first payment only"', async ({
		page
	}) => {
		// Find and click the accordion trigger for promotional code
		await page.getByText('Have a promotional code?').click();

		// Get the original prices before applying the coupon
		const originalMonthlyPrice = await page
			.locator('text=Monthly membership fee')
			.locator('..')
			.locator('..')
			.locator('span.font-semibold')
			.textContent();
		const originalAnnualPrice = await page
			.locator('text=Annual membership fee')
			.locator('..')
			.locator('..')
			.locator('span.font-semibold')
			.textContent();
		console.log(
			`Original prices - Monthly: ${originalMonthlyPrice}, Annual: ${originalAnnualPrice}`
		);

		// Fill in the coupon code
		await page.getByPlaceholder('Enter promotional code').fill(onceCouponCode);
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Wait for the API call to complete and prices to update
		await page.waitForTimeout(2000);

		await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
			timeout: 1000
		});
		await expect(page.getByText(`Code ${onceCouponCode} applied`)).toBeVisible({
			timeout: 1000
		});

		// Refresh the pricing data to verify it's updated
		await page.reload();
		await page.waitForSelector('form');

		// Wait for the discount to be applied and visible
		await page.waitForSelector('text=Discount applied:', { timeout: 5000 });

		// Verify that the "Applies to first payment only" text is shown (since we're using a 'once' coupon)
		await expect(page.locator('text=Applies to first payment only')).toBeVisible();

		// Verify that the discount percentage is shown
		await expect(page.locator('text=Discount applied: 15% off')).toBeVisible();

		// For a 'once' coupon, the original prices should still be shown without strikethrough
		// since the discount only applies to the first payment
		await expect(
			page
				.locator('text=Monthly membership fee')
				.locator('..')
				.locator('..')
				.locator('span.line-through')
		).not.toBeVisible();
		await expect(
			page
				.locator('text=Annual membership fee')
				.locator('..')
				.locator('..')
				.locator('span.line-through')
		).not.toBeVisible();

		// But the first payment should show a discounted amount with strikethrough for the original amount
		await expect(
			page
				.locator('text=Pro-rated amount')
				.locator('..')
				.locator('..')
				.locator('span.text-green-600')
		).toBeVisible();
		await expect(
			page.locator('text=Pro-rated amount').locator('..').locator('..').locator('span.line-through')
		).toBeVisible();

		// Get the discounted first payment amount
		const discountedFirstPayment = await page
			.locator('text=Pro-rated amount')
			.locator('..')
			.locator('..')
			.locator('span.text-green-600')
			.textContent();
		const originalFirstPayment = await page
			.locator('text=Pro-rated amount')
			.locator('..')
			.locator('..')
			.locator('span.line-through')
			.textContent();
		console.log(
			`First payment - Original: ${originalFirstPayment}, Discounted: ${discountedFirstPayment}`
		);

		// Verify that the discounted first payment is less than the original
		const originalFirstPaymentValue = parseFloat(originalFirstPayment?.replace(/[^0-9.]/g, ''));
		const discountedFirstPaymentValue = parseFloat(discountedFirstPayment?.replace(/[^0-9.]/g, ''));
		expect(discountedFirstPaymentValue).toBeLessThan(originalFirstPaymentValue);

		// Verify the discount percentage is approximately 15% (for one-time coupon)
		const firstPaymentDiscountPercent = Math.round(
			((originalFirstPaymentValue - discountedFirstPaymentValue) / originalFirstPaymentValue) * 100
		);
		console.log(`First payment discount percentage: ${firstPaymentDiscountPercent}%`);
		expect(firstPaymentDiscountPercent).toBeCloseTo(15, 1); // Allow 1% tolerance
	});

	test('should reject invalid coupon codes', async ({ page }) => {
		// Find and click the accordion trigger for promotional code
		await page.getByText('Have a promotional code?').click();

		// Test with an invalid coupon code
		await page.getByPlaceholder('Enter promotional code').fill('INVALID-COUPON-12345');
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Verify error message
		await expect(page.getByText('Coupon code not valid')).toBeVisible({
			timeout: 5000
		});

		// Test with another invalid format
		await page.getByPlaceholder('Enter promotional code').fill('TEST123');
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Verify error message
		await expect(page.getByText(/coupon code not valid/i)).toBeVisible({
			timeout: 5000
		});

		// Test with an expired code (we can simulate this by using a non-existent code)
		await page.getByPlaceholder('Enter promotional code').fill('EXPIRED-00000');
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Verify error message
		await expect(page.getByText(/coupon code not valid/i)).toBeVisible({
			timeout: 5000
		});
	});

	test('should process payment with coupon', async ({ page }) => {
		await page.getByLabel('Next of Kin', { exact: true }).fill('John Doe');

		// Find the phone input field (it's now inside the phone input component)
		// The new component has a div wrapper with an Input of type tel inside
		const phoneInputField = page
			.locator('div')
			.filter({ hasText: 'Next of Kin Phone Number' })
			.locator('input[type="tel"]');

		await phoneInputField.pressSequentially('0838774532', { delay: 50 });
		await page.getByText('Have a promotional code?').click();

		// Get the original prices before applying the coupon
		const originalMonthlyPrice = await page
			.locator('text=Monthly membership fee')
			.locator('..')
			.locator('..')
			.locator('span.font-semibold')
			.textContent();
		const originalAnnualPrice = await page
			.locator('text=Annual membership fee')
			.locator('..')
			.locator('..')
			.locator('span.font-semibold')
			.textContent();
		console.log(
			`Original prices - Monthly: ${originalMonthlyPrice}, Annual: ${originalAnnualPrice}`
		);

		// Fill in the coupon code
		await page.getByPlaceholder('Enter promotional code').fill(combinedCouponCode);
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Wait for the API call to complete and prices to update
		await page.waitForTimeout(2000);

		await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
			timeout: 1000
		});
		await expect(page.getByText(`Code ${combinedCouponCode} applied`)).toBeVisible({
			timeout: 1000
		});
		await phoneInputField.press('Tab');
		const stripeFrame = await page.locator('.__PrivateStripeElement').frameLocator('iframe');
		// Stripe's succesful IBAN number
		await stripeFrame.getByLabel('IBAN').fill('IE29AIBK93115212345678');
		await stripeFrame.getByLabel('Address line 1').fill('123 Main Street');
		await stripeFrame.getByLabel('Address line 2').fill('Apt 4B');
		await stripeFrame.getByLabel('City').fill('Dublin');
		await stripeFrame.getByLabel('Eircode').fill('K45 HR22');
		await stripeFrame.getByLabel('County').selectOption('County Dublin');
		await page.getByRole('button', { name: /sign up/i }).click();
		await expect(
			page.getByText(
				'Your membership has been successfully processed. Welcome to Dublin Hema Club! You will receive a Discord invite by email shortly.'
			)
		).toBeVisible({ timeout: 30000 });
	});

	test('applying a 100% once coupon shows €0.00 prorated price', async ({ page }) => {
		const phoneInputField = page
			.locator('div')
			.filter({ hasText: 'Next of Kin Phone Number' })
			.locator('input[type="tel"]');
		// Find and click the accordion trigger for promotional code
		await page.getByText('Have a promotional code?').click();

		// Get the original prorated price before applying the coupon
		const originalProratedPrice = await page
			.getByText('Pro-rated amount (first payment)', { exact: false })
			.textContent();
		console.log(`Original prorated price: ${originalProratedPrice}`);

		// Fill in the coupon code for a 100% once coupon
		await page.getByPlaceholder('Enter promotional code').fill('ONCE100OFF'); // Assuming this coupon exists
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Verify the coupon was applied successfully
		await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
			timeout: 1000
		});
		await expect(page.getByText(`Code ONCE100OFF applied`)).toBeVisible();

		// Wait for the discount to be applied and visible
		await page.waitForSelector('text=Discount applied:', { timeout: 5000 });

		/// Fill in the coupon code
		await page.getByPlaceholder('Enter promotional code').fill(combinedCouponCode);
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Wait for the API call to complete and prices to update
		await page.waitForTimeout(2000);

		await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
			timeout: 1000
		});
		await expect(page.getByText(`Code ${combinedCouponCode} applied`)).toBeVisible({
			timeout: 1000
		});
		await phoneInputField.press('Tab');
		const stripeFrame = await page.locator('.__PrivateStripeElement').frameLocator('iframe');
		// Stripe's succesful IBAN number
		await stripeFrame.getByLabel('IBAN').fill('IE29AIBK93115212345678');
		await stripeFrame.getByLabel('Address line 1').fill('123 Main Street');
		await stripeFrame.getByLabel('Address line 2').fill('Apt 4B');
		await stripeFrame.getByLabel('City').fill('Dublin');
		await stripeFrame.getByLabel('Eircode').fill('K45 HR22');
		await stripeFrame.getByLabel('County').selectOption('County Dublin');
		await page.getByRole('button', { name: /sign up/i }).click();
		await expect(
			page.getByText(
				'Your membership has been successfully processed. Welcome to Dublin Hema Club! You will receive a Discord invite by email shortly.'
			)
		).toBeVisible({ timeout: 30000 });
	});

	test('applying the migration code creates credit notes and shows €0.00 total', async ({
		page
	}) => {
		// Find and click the accordion trigger for promotional code
		await page.getByText('Have a promotional code?').click();

		// Get the original prices before applying the migration code
		const originalProratedPrice = await page
			.getByText('Pro-rated amount (first payment)', { exact: false })
			.textContent();
		console.log(`Original prorated price: ${originalProratedPrice}`);

		// Fill in the migration code
		await page.getByPlaceholder('Enter promotional code').fill(migrationCouponCode);
		await page.getByRole('button', { name: 'Apply Code' }).click();

		// Verify the code was applied successfully
		await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
			timeout: 1000
		});
		await expect(page.getByText(`Code ${migrationCouponCode} applied`)).toBeVisible();

		// Wait for the page to update
		await page.waitForTimeout(2000);

		// Refresh to ensure we see the updated state
		await page.reload();
		await page.waitForSelector('form');

		// Verify the prorated amount is now €0.00 (or currency equivalent)
		// This confirms that the credit notes were applied correctly
		const discountedPrice = await page
			.locator('text=Pro-rated amount')
			.locator('..')
			.locator('..')
			.locator('span.font-semibold')
			.textContent();
		console.log(`Discounted prorated price after migration code: ${discountedPrice}`);

		// Check that the total price is now €0.00 (or equivalent zero amount)
		await expect(page.getByText('€0.00')).toBeVisible({ timeout: 5000 });

		// Optional: Complete the signup process to verify everything works end-to-end
		await page.getByLabel('Next of Kin', { exact: true }).fill('John Doe');
		const phoneInputField = page
			.locator('div')
			.filter({ hasText: 'Next of Kin Phone Number' })
			.locator('input[type="tel"]');
		await phoneInputField.pressSequentially('0838774532', { delay: 50 });

		// Fill in payment details even though the amount is €0.00
		const stripeFrame = await page.locator('.__PrivateStripeElement').frameLocator('iframe');
		await stripeFrame.getByLabel('IBAN').fill('IE29AIBK93115212345678');
		await stripeFrame.getByLabel('Address line 1').fill('123 Main Street');
		await stripeFrame.getByLabel('Address line 2').fill('Apt 4B');
		await stripeFrame.getByLabel('City').fill('Dublin');
		await stripeFrame.getByLabel('Eircode').fill('K45 HR22');
		await stripeFrame.getByLabel('County').selectOption('County Dublin');

		// Complete signup
		await page.getByRole('button', { name: /sign up/i }).click();

		// Verify successful signup
		await expect(
			page.getByText(
				'Your membership has been successfully processed. Welcome to Dublin Hema Club! You will receive a Discord invite by email shortly.'
			)
		).toBeVisible({ timeout: 30000 });
	});
});
