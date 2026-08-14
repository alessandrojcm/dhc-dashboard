import { expect, test, type Page } from "@playwright/test";
import "dotenv/config";
import {
	ANNUAL_FEE_LOOKUP,
	MEMBERSHIP_FEE_LOOKUP_NAME,
} from "../src/lib/server/constants";
import {
	routeSuccessfulDiscordAcceptance,
	setupInvitedUser,
	stripeClient,
} from "./setupFunctions";

type InvitedUser = Awaited<ReturnType<typeof setupInvitedUser>>;

function signupUrl(invitation: InvitedUser) {
	return `/members/signup/${invitation.invitationId}?email=${encodeURIComponent(invitation.email)}&dateOfBirth=${encodeURIComponent(invitation.date_of_birth.format("YYYY-MM-DD"))}`;
}

async function openSignup(page: Page, invitation: InvitedUser) {
	await routeSuccessfulDiscordAcceptance(page, invitation.invitationId);
	await page.goto(signupUrl(invitation));
	const verifyButton = page.getByRole("button", { name: /verify invitation/i });
	await expect(verifyButton).toBeVisible();
	await page.waitForLoadState("networkidle");
	await verifyButton.click();
	await page.getByRole("link", { name: "Continue to Discord" }).click();
	await page.getByLabel(/next of kin$/i).waitFor({ state: "visible" });
}

async function openCouponForm(page: Page) {
	const trigger = page.getByRole("button", {
		name: "Have a promotional code?",
	});
	await trigger.scrollIntoViewIfNeeded();
	await trigger.click();
	await page
		.getByPlaceholder("Enter promotional code")
		.waitFor({ state: "visible" });
}

async function applyCoupon(page: Page, code: string) {
	await openCouponForm(page);
	await page.getByPlaceholder("Enter promotional code").fill(code);
	await page.getByRole("button", { name: "Apply Code" }).click();
	await expect(page.getByText(`Code ${code} applied`)).toBeVisible({
		timeout: 15_000,
	});
}

function pricingRow(page: Page, label: string) {
	return page
		.locator(".flex.justify-between")
		.filter({ hasText: label })
		.first();
}

test.describe("Member Signup - Coupon Codes", () => {
	test.describe.configure({ timeout: 60_000 });

	// Coupon codes for testing (created once, reused across tests)
	let annualCouponCode: string;
	let monthlyCouponCode: string;
	let combinedCouponCode: string;
	let onceCouponCode: string;
	let once100CouponCode: string;
	let complimentaryCouponCode: string;
	let complimentaryPromotionId: string;
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
			complimentaryCoupon,
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
			// Complimentary Membership - all recurring fees remain free
			stripeClient.coupons.create({
				percent_off: 100,
				duration: "forever",
				name: "Complimentary Membership",
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
			complimentaryPromotion,
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
			stripeClient.promotionCodes.create({
				promotion: {
					coupon: complimentaryCoupon.id,
					type: "coupon",
				},
				code: `COMPLIMENTARY-${Date.now().toString().slice(-6)}`,
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
		complimentaryCouponCode = complimentaryPromotion.code;
		complimentaryPromotionId = complimentaryPromotion.id;
		migrationCouponCode = migrationPromotion.code;

		// Save promotion code IDs for cleanup
		promotionCodeIds = [
			annualPromotion.id,
			monthlyPromotion.id,
			combinedPromotion.id,
			oncePromotion.id,
			once100Promotion.id,
			complimentaryPromotion.id,
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

	test.describe("Coupon application", () => {
		let invitation: InvitedUser;

		test.beforeEach(async ({ page }) => {
			invitation = await setupInvitedUser();
			await openSignup(page, invitation);
		});

		test.afterEach(async () => {
			await invitation?.cleanUp();
		});

		for (const coupon of [
			{ name: "annual", code: () => annualCouponCode },
			{ name: "monthly", code: () => monthlyCouponCode },
		]) {
			test(`applies a valid ${coupon.name} coupon`, async ({ page }) => {
				await applyCoupon(page, coupon.code());
			});
		}

		test("shows discounted recurring prices for a permanent coupon", async ({
			page,
		}) => {
			const monthlyRow = pricingRow(page, "Monthly membership fee");
			const annualRow = pricingRow(page, "Annual membership fee");
			const originalMonthlyPrice = await monthlyRow
				.locator("span.font-semibold")
				.textContent();
			const originalAnnualPrice = await annualRow
				.locator("span.font-semibold")
				.textContent();

			await applyCoupon(page, combinedCouponCode);

			const discountedMonthlyPrice = await monthlyRow
				.locator("span.text-green-600")
				.textContent();
			const discountedAnnualPrice = await annualRow
				.locator("span.text-green-600")
				.textContent();

			await expect(monthlyRow.locator("span.line-through")).toBeVisible();
			await expect(annualRow.locator("span.line-through")).toBeVisible();
			await expect(page.getByText("Discount applied: 10% off")).toBeVisible();
			await expect(
				page.getByText("Applies to all future payments"),
			).toBeVisible();

			const currencyValue = (value: string | null) =>
				Number(value?.replace(/[^0-9.]/g, "") ?? 0);
			expect(currencyValue(discountedMonthlyPrice)).toBeLessThan(
				currencyValue(originalMonthlyPrice),
			);
			expect(currencyValue(discountedAnnualPrice)).toBeLessThan(
				currencyValue(originalAnnualPrice),
			);
		});

		test("shows a one-time coupon on the first payment only", async ({
			page,
		}) => {
			await applyCoupon(page, onceCouponCode);

			await expect(page.getByText("Discount applied: 15% off")).toBeVisible();
			await expect(
				page.getByText("Applies to first payment only"),
			).toBeVisible();
			await expect(
				pricingRow(page, "Monthly membership fee").locator("span.line-through"),
			).toHaveCount(0);
			await expect(
				pricingRow(page, "Annual membership fee").locator("span.line-through"),
			).toHaveCount(0);
			await expect(page.getByText(/€0\.00/)).toHaveCount(0);
		});

		test("rejects invalid coupon codes", async ({ page }) => {
			await openCouponForm(page);
			const couponInput = page.getByPlaceholder("Enter promotional code");

			for (const code of ["INVALID-COUPON-12345", "TEST123"]) {
				await couponInput.fill(code);
				await page.getByRole("button", { name: "Apply Code" }).click();
				await expect(
					page.getByText("Could not apply promotion code"),
				).toBeVisible({ timeout: 15_000 });
			}
		});

		for (const coupon of [
			{ name: "100% one-time coupon", code: () => once100CouponCode },
			{ name: "migration coupon", code: () => migrationCouponCode },
		]) {
			test(`${coupon.name} makes the first payment free`, async ({ page }) => {
				await applyCoupon(page, coupon.code());

				await expect(
					page.getByText("Discount applied: 100% off"),
				).toBeVisible();
				await expect(
					page.getByText("Applies to first payment only"),
				).toBeVisible();
				await expect(
					pricingRow(page, "Total").getByText(/€0\.00/),
				).toBeVisible();
			});
		}
	});

	for (const coupon of [
		{
			name: "a percentage coupon",
			code: () => combinedCouponCode,
			discount: "10% off",
			promotionId: undefined,
		},
		{
			name: "a complimentary 100% coupon",
			code: () => complimentaryCouponCode,
			discount: "100% off",
			promotionId: () => complimentaryPromotionId,
		},
	]) {
		test(`processes Membership acceptance with ${coupon.name}`, async ({
			page,
		}) => {
			const invitation = await setupInvitedUser();

			try {
				await openSignup(page, invitation);
				await page.getByLabel(/next of kin$/i).fill("John Doe");
				const phoneInput = page.getByLabel(/next of kin phone number/i);
				await phoneInput.pressSequentially("0838774532", { delay: 50 });
				await phoneInput.press("Tab");
				await applyCoupon(page, coupon.code());
				await expect(
					page.getByText(`Discount applied: ${coupon.discount}`),
				).toBeVisible();

				await expect(page.locator("#payment-element-state")).toHaveAttribute(
					"data-ready",
					"true",
				);
				const stripeFrame = page
					.locator(".__PrivateStripeElement")
					.frameLocator("iframe");
				await expect(stripeFrame.getByLabel("IBAN")).toBeVisible({
					timeout: 15_000,
				});
				await stripeFrame.getByLabel("IBAN").fill("IE29AIBK93115212345678");
				await stripeFrame.getByLabel("Email").fill(invitation.email);
				await stripeFrame.getByLabel("Full name").fill("John Doe");
				await stripeFrame.getByLabel("Address line 1").fill("123 Main Street");
				await stripeFrame.getByLabel("Address line 2").fill("Apt 4B");
				await stripeFrame
					.getByLabel("Country or region")
					.selectOption("Ireland");
				await stripeFrame.getByLabel("City").fill("Dublin");
				await stripeFrame.getByLabel("Eircode").fill("K45 HR22");
				await stripeFrame.getByLabel("County").selectOption("Dublin");
				await expect(page.locator("#payment-element-state")).toHaveAttribute(
					"data-complete",
					"true",
				);

				await page.getByRole("button", { name: /sign up/i }).click();
				await expect(page.getByText(/You are not signed in\./)).toBeVisible({
					timeout: 30_000,
				});
				await expect(
					page.getByRole("link", { name: "Go to sign in" }),
				).toHaveAttribute("href", "/auth");

				if (coupon.promotionId) {
					const customers = await stripeClient.customers.list({
						email: invitation.email,
						limit: 2,
					});
					expect(customers.data).toHaveLength(1);

					const subscriptions = await stripeClient.subscriptions.list({
						customer: customers.data[0].id,
						status: "all",
						limit: 10,
						expand: ["data.discounts"],
					});
					expect(subscriptions.data).toHaveLength(2);

					for (const subscription of subscriptions.data) {
						const promotionIds = subscription.discounts.flatMap((discount) => {
							if (typeof discount === "string" || !discount.promotion_code) {
								return [];
							}

							return [
								typeof discount.promotion_code === "string"
									? discount.promotion_code
									: discount.promotion_code.id,
							];
						});

						expect(promotionIds).toContain(coupon.promotionId());
					}
				}
			} finally {
				await invitation.cleanUp();
			}
		});
	}
});
