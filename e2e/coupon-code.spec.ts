import { expect, test } from "@playwright/test";
import "dotenv/config";
import {
	ANNUAL_FEE_LOOKUP,
	MEMBERSHIP_FEE_LOOKUP_NAME,
} from "../src/lib/server/constants";
import { setupInvitedUser, stripeClient } from "./setupFunctions";

test.describe("Member Signup - Coupon Codes", () => {
	// Coupon codes for testing (created once, reused across tests)
	let annualCouponCode: string;
	let monthlyCouponCode: string;
	let combinedCouponCode: string;
	let onceCouponCode: string;
	let once100CouponCode: string;
	let migrationCouponCode: string;
	// Promotion code IDs for cleanup
	let promotionCodeIds: string[] = [];

	test.beforeAll(async () => {
		// Create coupons once - they can be reused across all tests

		const migrationCode =
			process.env.PUBLIC_DASHBOARD_MIGRATION_CODE || "DHCDASHBOARD";
		const existingPromos = await stripeClient.promotionCodes.list({
			code: migrationCode,
			limit: 10,
		});
		for (const promo of existingPromos.data) {
			if (promo.active) {
				await stripeClient.promotionCodes.update(promo.id, { active: false });
			}
			const couponId =
				typeof promo.promotion?.coupon === "string"
					? promo.promotion.coupon
					: promo.promotion?.coupon?.id;
			if (couponId) {
				try {
					await stripeClient.coupons.del(couponId);
				} catch {}
			}
		}

		const [annualPrices, monthlyPrices] = await Promise.all([
			stripeClient.prices.list({
				lookup_keys: [ANNUAL_FEE_LOOKUP],
			}),
			stripeClient.prices.list({
				lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME],
			}),
		]);

		const annualPriceId = annualPrices.data[0]?.id;
		const monthlyPriceId = monthlyPrices.data[0]?.id;

		if (!annualPriceId || !monthlyPriceId) {
			throw new Error("Could not find price IDs for membership fees");
		}

		// Create coupons in Stripe
		const [
			annualCoupon,
			monthlyCoupon,
			combinedCoupon,
			onceCoupon,
			once100Coupon,
			migrationCoupon,
		] = await Promise.all([
			// Coupon for annual fee only - 20% off
			stripeClient.coupons.create({
				percent_off: 20,
				duration: "once",
				name: "Annual Fee Test Discount",
				applies_to: {
					products: [annualPrices.data[0].product as string],
				},
			}),
			// Coupon for monthly fee only - 15% off
			stripeClient.coupons.create({
				percent_off: 15,
				duration: "once",
				name: "Monthly Fee Test Discount",
				applies_to: {
					products: [monthlyPrices.data[0].product as string],
				},
			}),
			// Coupon for both fees - 10% off (permanent discount)
			stripeClient.coupons.create({
				percent_off: 10,
				duration: "forever",
				name: "Combined Test Discount (Permanent)",
			}),
			// Coupon for both fees - 15% off (one-time discount)
			stripeClient.coupons.create({
				percent_off: 15,
				duration: "once",
				name: "One-time Test Discount",
			}),
			// Coupon for both fees - 100% off (one-time discount)
			stripeClient.coupons.create({
				percent_off: 100,
				duration: "once",
				name: "100% Off First Payment",
			}),
			// Special migration coupon for testing the migration code functionality
			stripeClient.coupons.create({
				percent_off: 100,
				duration: "once",
				name: "Migration Discount",
			}),
		]);

		// Create promotion codes for the coupons
		const [
			annualPromotion,
			monthlyPromotion,
			combinedPromotion,
			oncePromotion,
			once100Promotion,
			migrationPromotion,
		] = await Promise.all([
			stripeClient.promotionCodes.create({
				promotion: {
					coupon: annualCoupon.id,
					type: "coupon",
				},
				code: `ANNUAL-${Date.now().toString().slice(-6)}`,
				max_redemptions: 5,
			}),
			stripeClient.promotionCodes.create({
				promotion: {
					coupon: monthlyCoupon.id,
					type: "coupon",
				},
				code: `MONTHLY-${Date.now().toString().slice(-6)}`,
				max_redemptions: 5,
			}),
			stripeClient.promotionCodes.create({
				promotion: {
					coupon: combinedCoupon.id,
					type: "coupon",
				},
				code: `COMBINED-${Date.now().toString().slice(-6)}`,
				max_redemptions: 5,
			}),
			stripeClient.promotionCodes.create({
				promotion: {
					coupon: onceCoupon.id,
					type: "coupon",
				},
				code: `ONCE-${Date.now().toString().slice(-6)}`,
				max_redemptions: 5,
			}),
			stripeClient.promotionCodes.create({
				promotion: {
					coupon: once100Coupon.id,
					type: "coupon",
				},
				code: `ONCE100OFF-${Date.now().toString().slice(-6)}`,
				max_redemptions: 5,
			}),
			// Create the migration code with the exact name from the environment variable
			stripeClient.promotionCodes.create({
				promotion: {
					coupon: migrationCoupon.id,
					type: "coupon",
				},
				code: process.env.PUBLIC_DASHBOARD_MIGRATION_CODE || "DHCDASHBOARD",
				max_redemptions: 5,
			}),
		]);

		// Save promotion codes for tests
		annualCouponCode = annualPromotion.code;
		monthlyCouponCode = monthlyPromotion.code;
		combinedCouponCode = combinedPromotion.code;
		onceCouponCode = oncePromotion.code;
		once100CouponCode = once100Promotion.code;
		migrationCouponCode = migrationPromotion.code;

		// Save promotion code IDs for cleanup
		promotionCodeIds = [
			annualPromotion.id,
			monthlyPromotion.id,
			combinedPromotion.id,
			oncePromotion.id,
			once100Promotion.id,
			migrationPromotion.id,
		];
	});

	test.afterAll(async () => {
		// Clean up all promotion codes
		for (const promotionId of promotionCodeIds) {
			try {
				const promotion =
					await stripeClient.promotionCodes.retrieve(promotionId);
				await stripeClient.promotionCodes.update(promotionId, {
					active: false,
				});

				const couponId =
					typeof promotion.promotion?.coupon === "string"
						? promotion.promotion.coupon
						: promotion.promotion?.coupon?.id;
				if (couponId) {
					await stripeClient.coupons.del(couponId);
				}
			} catch (error) {
				console.error(
					`Error cleaning up promotion code ${promotionId}:`,
					error,
				);
			}
		}
	});

	// GROUP 1: Read-only coupon application tests (tests 1-4)
	// These tests only apply coupons and check the UI, they don't modify invitation state
	test.describe("Coupon Application Tests", () => {
		let testData: Awaited<ReturnType<typeof setupInvitedUser>>;

		test.beforeAll(async () => {
			// Create ONE invitation for all read-only tests
			testData = await setupInvitedUser();
		});

		test.afterAll(async () => {
			// Clean up the invitation after all tests in this group
			if (testData?.cleanUp) {
				await testData.cleanUp();
			}
		});

		test.beforeEach(async ({ page }) => {
			await page.goto(
				`/members/signup/${testData.invitationId}?email=${encodeURIComponent(testData.email)}&dateOfBirth=${encodeURIComponent(
					testData.date_of_birth.format("YYYY-MM-DD"),
				)}`,
			);

			// Wait for page to load and check if verification is needed
			const verifyButton = page.getByRole("button", {
				name: /verify invitation/i,
			});

			// Wait a bit for the page to load, then check if verify button exists
			try {
				await verifyButton.waitFor({ state: "visible", timeout: 5000 });
				await verifyButton.click();
			} catch {
				// Verify button not found - invitation might be auto-verified
			}

			await page.getByLabel(/next of kin$/i).waitFor({ state: "visible" });
		});

		test("should apply valid annual coupon code", async ({ page }) => {
			const accordionTrigger = page.getByRole("button", {
				name: "Have a promotional code?",
			});
			await accordionTrigger.scrollIntoViewIfNeeded();
			await accordionTrigger.click();

			const couponInput = page.getByPlaceholder("Enter promotional code");
			await couponInput.waitFor({ state: "visible", timeout: 10000 });
			await couponInput.fill(annualCouponCode);

			// The pricing automatically updates when coupon input changes
			// Wait for the success message to appear
			await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
				timeout: 3000,
			});
			await expect(
				page.getByText(`Code ${annualCouponCode} applied`),
			).toBeVisible({ timeout: 5000 });
		});

		test("should apply valid monthly coupon code", async ({ page }) => {
			const accordionTrigger = page.getByRole("button", {
				name: "Have a promotional code?",
			});
			await accordionTrigger.scrollIntoViewIfNeeded();
			await accordionTrigger.click();

			// Fill in the coupon code - pricing auto-updates via reactive binding
			const couponInput = page.getByPlaceholder("Enter promotional code");
			await couponInput.waitFor({ state: "visible", timeout: 10000 });
			await couponInput.fill(monthlyCouponCode);

			// Wait for the success message (pricing auto-updates when input changes)
			await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
				timeout: 3000,
			});
			await expect(
				page.getByText(`Code ${monthlyCouponCode} applied`),
			).toBeVisible({ timeout: 5000 });
		});

		test("should apply valid combined coupon code and show discounted prices", async ({
			page,
		}) => {
			const accordionTrigger = page.getByRole("button", {
				name: "Have a promotional code?",
			});
			await accordionTrigger.scrollIntoViewIfNeeded();
			await accordionTrigger.click();

			const originalMonthlyPrice = await page
				.locator("text=Monthly membership fee")
				.locator("..")
				.locator("..")
				.locator("span.font-semibold")
				.textContent();
			const originalAnnualPrice = await page
				.locator("text=Annual membership fee")
				.locator("..")
				.locator("..")
				.locator("span.font-semibold")
				.textContent();

			const couponInput = page.getByPlaceholder("Enter promotional code");
			await couponInput.waitFor({ state: "visible", timeout: 10000 });
			await couponInput.fill(combinedCouponCode);

			await expect(
				page.getByText(`Code ${combinedCouponCode} applied`),
			).toBeVisible({ timeout: 10000 });

			await accordionTrigger.click();
			const applyButton = page.getByRole("button", { name: "Apply Code" });
			await applyButton.waitFor({ state: "visible", timeout: 5000 });
			await applyButton.click();

			await expect(page.getByText(/Discount applied:/)).toBeVisible({
				timeout: 10000,
			});

			// Check that the discounted prices are shown
			const discountedMonthlyPrice = await page
				.locator("text=Monthly membership fee")
				.locator("..")
				.locator("..")
				.locator("span.text-green-600")
				.textContent();
			const discountedAnnualPrice = await page
				.locator("text=Annual membership fee")
				.locator("..")
				.locator("..")
				.locator("span.text-green-600")
				.textContent();

			// Verify that the original prices are shown with strikethrough
			await expect(
				page
					.locator("text=Monthly membership fee")
					.locator("..")
					.locator("..")
					.locator("span.line-through"),
			).toBeVisible();
			await expect(
				page
					.locator("text=Annual membership fee")
					.locator("..")
					.locator("..")
					.locator("span.line-through"),
			).toBeVisible();

			// Verify that the discount percentage is shown
			await expect(page.locator("text=Discount applied:")).toBeVisible();

			// Verify that the "Applies to all future payments" text is shown (since we're using a 'forever' coupon)
			await expect(
				page.locator("text=Applies to all future payments"),
			).toBeVisible();

			// Verify that the discounted prices are less than the original prices
			const originalMonthlyValue = parseFloat(
				originalMonthlyPrice?.replace(/[^0-9.]/g, "") ?? "0",
			);
			const discountedMonthlyValue = parseFloat(
				discountedMonthlyPrice?.replace(/[^0-9.]/g, "") ?? "0",
			);
			const originalAnnualValue = parseFloat(
				originalAnnualPrice?.replace(/[^0-9.]/g, "") ?? "0",
			);
			const discountedAnnualValue = parseFloat(
				discountedAnnualPrice?.replace(/[^0-9.]/g, "") ?? "0",
			);

			expect(discountedMonthlyValue).toBeLessThan(originalMonthlyValue);
			expect(discountedAnnualValue).toBeLessThan(originalAnnualValue);

			// Verify the discount percentage is approximately 10% (for combined coupon)
			const monthlyDiscountPercent = Math.round(
				((originalMonthlyValue - discountedMonthlyValue) /
					originalMonthlyValue) *
					100,
			);
			const annualDiscountPercent = Math.round(
				((originalAnnualValue - discountedAnnualValue) / originalAnnualValue) *
					100,
			);

			expect(monthlyDiscountPercent).toBeCloseTo(10, 1); // Allow 1% tolerance
			expect(annualDiscountPercent).toBeCloseTo(10, 1); // Allow 1% tolerance
		});

		test('should apply one-time coupon and show "Applies to first payment only"', async ({
			page,
		}) => {
			const accordionTrigger = page.getByRole("button", {
				name: "Have a promotional code?",
			});
			await accordionTrigger.scrollIntoViewIfNeeded();
			await accordionTrigger.click();

			const couponInput = page.getByPlaceholder("Enter promotional code");
			await couponInput.waitFor({ state: "visible", timeout: 10000 });
			await couponInput.fill(onceCouponCode);

			await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
				timeout: 3000,
			});
			await expect(
				page.getByText(`Code ${onceCouponCode} applied`),
			).toBeVisible({
				timeout: 5000,
			});

			await expect(page.getByText("Discount applied:")).toBeVisible({
				timeout: 5000,
			});

			await expect(
				page.getByText(/Applies to first payment only/),
			).toBeVisible();

			await expect(page.getByText(/Discount applied: 15% off/)).toBeVisible();

			// For a 'once' coupon, the original prices should still be shown without strikethrough
			// since the discount only applies to the first payment
			await expect(
				page
					.locator("text=Monthly membership fee")
					.locator("..")
					.locator("..")
					.locator("span.line-through"),
			).not.toBeVisible();
			await expect(
				page
					.locator("text=Annual membership fee")
					.locator("..")
					.locator("..")
					.locator("span.line-through"),
			).not.toBeVisible();

			await expect(page.getByText(/€0\.00/)).not.toBeVisible();
		});
	});

	// GROUP 2: Tests that modify invitation state (tests 5-6)
	test.describe("Coupon Validation and Payment Tests", () => {
		// Test 6: Validation test (doesn't complete signup, can reuse invitation)
		test.describe("should reject invalid coupon codes", () => {
			let testData: Awaited<ReturnType<typeof setupInvitedUser>>;

			test.beforeAll(async () => {
				testData = await setupInvitedUser();
			});

			test.afterAll(async () => {
				if (testData?.cleanUp) {
					await testData.cleanUp();
				}
			});

			test("validation test", async ({ page }) => {
				await page.goto(
					`/members/signup/${testData.invitationId}?email=${encodeURIComponent(testData.email)}&dateOfBirth=${encodeURIComponent(
						testData.date_of_birth.format("YYYY-MM-DD"),
					)}`,
				);

				// Wait for page to load and check if verification is needed
				const verifyButton = page.getByRole("button", {
					name: /verify invitation/i,
				});

				try {
					await verifyButton.waitFor({ state: "visible", timeout: 5000 });
					await verifyButton.click();
				} catch {
					// Verify button not found
				}

				await page.getByLabel(/next of kin$/i).waitFor({ state: "visible" });
				const accordionTrigger = page.getByRole("button", {
					name: "Have a promotional code?",
				});
				await accordionTrigger.scrollIntoViewIfNeeded();
				await accordionTrigger.click();

				const couponInput = page.getByPlaceholder("Enter promotional code");
				await couponInput.waitFor({ state: "visible", timeout: 10000 });

				await couponInput.fill("INVALID-COUPON-12345");
				await expect(
					page.getByText("Error loading pricing information"),
				).toBeVisible({ timeout: 10000 });

				await page.reload();
				await page.getByLabel(/next of kin$/i).waitFor({ state: "visible" });

				const accordionTrigger2 = page.getByRole("button", {
					name: "Have a promotional code?",
				});
				await accordionTrigger2.scrollIntoViewIfNeeded();
				await accordionTrigger2.click();

				const couponInput2 = page.getByPlaceholder("Enter promotional code");
				await couponInput2.waitFor({ state: "visible", timeout: 10000 });

				await couponInput2.fill("TEST123");
				await expect(
					page.getByText("Error loading pricing information"),
				).toBeVisible({ timeout: 10000 });
			});
		});

		// Test 7: Payment test (completes signup, needs its own invitation)
		test.describe("should process payment with coupon", () => {
			let testData: Awaited<ReturnType<typeof setupInvitedUser>>;

			test.beforeAll(async () => {
				testData = await setupInvitedUser();
			});

			test.afterAll(async () => {
				if (testData?.cleanUp) {
					await testData.cleanUp();
				}
			});

			test("payment test", async ({ page }) => {
				await page.goto(
					`/members/signup/${testData.invitationId}?email=${encodeURIComponent(testData.email)}&dateOfBirth=${encodeURIComponent(
						testData.date_of_birth.format("YYYY-MM-DD"),
					)}`,
				);

				// Wait for page to load and check if verification is needed
				const verifyButton = page.getByRole("button", {
					name: /verify invitation/i,
				});

				try {
					await verifyButton.waitFor({ state: "visible", timeout: 5000 });
					await verifyButton.click();
				} catch {
					// Verify button not found
				}

				await page.getByLabel(/next of kin$/i).waitFor({ state: "visible" });

				// Fill in next of kin details
				await page.getByLabel(/next of kin$/i).fill("John Doe");

				const phoneInputField = page.getByLabel(/next of kin phone number/i);

				// Wait for the phone input field to be ready
				await phoneInputField.waitFor({ state: "visible", timeout: 10000 });
				await phoneInputField.fill("0838774532");

				const accordionTrigger = page.getByRole("button", {
					name: "Have a promotional code?",
				});
				await accordionTrigger.scrollIntoViewIfNeeded();
				await accordionTrigger.click();

				const couponInput = page.getByPlaceholder("Enter promotional code");
				await couponInput.waitFor({ state: "visible", timeout: 10000 });
				await couponInput.fill(combinedCouponCode);

				await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
					timeout: 3000,
				});
				await expect(
					page.getByText(`Code ${combinedCouponCode} applied`),
				).toBeVisible({ timeout: 5000 });

				await accordionTrigger.click();

				const applyButton = page.getByRole("button", { name: "Apply Code" });
				await applyButton.waitFor({ state: "visible", timeout: 5000 });
				await applyButton.click();

				await expect(page.getByText(/Discount applied:/)).toBeVisible({
					timeout: 10000,
				});

				// Interact with the embedded Stripe payment form (SEPA Direct Debit)
				const stripeFrame = await page
					.locator(".__PrivateStripeElement")
					.frameLocator("iframe");
				await stripeFrame.getByLabel("IBAN").fill("IE29AIBK93115212345678");
				await stripeFrame.getByLabel("Address line 1").fill("123 Main Street");
				await stripeFrame.getByLabel("Address line 2").fill("Apt 4B");
				await stripeFrame
					.getByLabel("Country or region")
					.selectOption("Ireland");
				await stripeFrame.getByLabel("City").fill("Dublin");
				await stripeFrame.getByLabel("Eircode").fill("K45 HR22");
				await stripeFrame.getByLabel("County").selectOption("Dublin");

				const submitButton = page.getByRole("button", { name: /sign up/i });
				await submitButton.click();

				await expect(
					page.getByText(
						"Your membership has been successfully processed. Welcome to Dublin Hema Club! You will receive a Discord invite by email shortly.",
					),
				).toBeVisible({ timeout: 30000 });
			});
		});
	});

	// GROUP 3: Special coupon tests (tests 7-8)
	test.describe("Special Coupon Tests", () => {
		let testData: Awaited<ReturnType<typeof setupInvitedUser>>;

		test.beforeAll(async () => {
			// Create ONE invitation for these tests
			testData = await setupInvitedUser();
		});

		test.afterAll(async () => {
			// Clean up the invitation after all tests in this group
			if (testData?.cleanUp) {
				await testData.cleanUp();
			}
		});

		test.beforeEach(async ({ page }) => {
			await page.goto(
				`/members/signup/${testData.invitationId}?email=${encodeURIComponent(testData.email)}&dateOfBirth=${encodeURIComponent(
					testData.date_of_birth.format("YYYY-MM-DD"),
				)}`,
			);

			// Wait for page to load and check if verification is needed
			const verifyButton = page.getByRole("button", {
				name: /verify invitation/i,
			});

			try {
				await verifyButton.waitFor({ state: "visible", timeout: 5000 });
				await verifyButton.click();
			} catch {
				// Verify button not found
			}

			await page.getByLabel(/next of kin$/i).waitFor({ state: "visible" });
		});

		test("applying a 100% once coupon shows €0.00 prorated price", async ({
			page,
		}) => {
			const accordionTrigger = page.getByRole("button", {
				name: "Have a promotional code?",
			});
			await accordionTrigger.scrollIntoViewIfNeeded();
			await accordionTrigger.click();

			const couponInput = page.getByPlaceholder("Enter promotional code");
			await couponInput.waitFor({ state: "visible", timeout: 10000 });
			await couponInput.fill(once100CouponCode);

			await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
				timeout: 3000,
			});
			await expect(
				page.getByText(`Code ${once100CouponCode} applied`),
			).toBeVisible({ timeout: 5000 });

			await expect(page.getByText("Discount applied:")).toBeVisible({
				timeout: 5000,
			});

			await expect(
				page.getByText(/Applies to first payment only/),
			).toBeVisible();

			// The prorated price total should show €0.00
			await expect(
				page
					.locator(".flex.justify-between")
					.filter({ hasText: "Total" })
					.getByText(/€0\.00/),
			).toBeVisible();
		});

		test("applying the migration code shows €0.00 total", async ({ page }) => {
			const accordionTrigger = page.getByRole("button", {
				name: "Have a promotional code?",
			});
			await accordionTrigger.scrollIntoViewIfNeeded();
			await accordionTrigger.click();

			const couponInput = page.getByPlaceholder("Enter promotional code");
			await couponInput.waitFor({ state: "visible", timeout: 10000 });
			await couponInput.fill(migrationCouponCode);

			await expect(page.getByText(/coupon code not valid/i)).not.toBeVisible({
				timeout: 3000,
			});
			await expect(
				page.getByText(`Code ${migrationCouponCode} applied`),
			).toBeVisible({ timeout: 5000 });

			await accordionTrigger.click();
			const applyButton = page.getByRole("button", { name: "Apply Code" });
			await applyButton.waitFor({ state: "visible", timeout: 5000 });
			await applyButton.click();

			// Check that 100% discount is applied
			await expect(page.getByText(/Discount applied: 100% off/)).toBeVisible({
				timeout: 10000,
			});

			// The prorated price total should show €0.00
			await expect(
				page
					.locator(".flex.justify-between")
					.filter({ hasText: "Total" })
					.getByText(/€0\.00/),
			).toBeVisible();
		});
	});
});
