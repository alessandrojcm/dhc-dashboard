import {
	expect,
	test,
	type APIRequestContext,
	type Page,
} from "@playwright/test";
import { MEMBERSHIP_FEE_LOOKUP_NAME } from "../src/lib/server/constants";
import {
	routeSuccessfulDiscordAcceptance,
	setupInvitedUser,
	stripeClient,
} from "./setupFunctions";
import { fillInvitationCredentials } from "./invitationSignup";
import { API_BASE_URL } from "./e2eApi";
import * as v from "valibot";

const MoneySchema = v.object({
	amount: v.number(),
	currency: v.string(),
	precision: v.number(),
});

// Mirrors DhcWeb.InvitationsJSON.render("pricing.json") /
// Dhc.Invitations.Pricing.generate_pricing_info/1.
const PricingSchema = v.object({
	data: v.object({
		monthlyFee: MoneySchema,
		annualFee: MoneySchema,
		proratedPrice: MoneySchema,
		discountPercentage: v.number(),
		discountedMonthlyFee: v.optional(MoneySchema),
	}),
});

type PricingDTO = v.InferOutput<typeof PricingSchema>;
type StripeReference = string | { id: string } | null | undefined;
type InvitedUser = Awaited<ReturnType<typeof setupInvitedUser>>;

// Stripe returns expanded discounts with their backend-applied coupon source.
const DiscountSchema = v.object({
	source: v.object({
		type: v.literal("coupon"),
		coupon: v.union([v.string(), v.object({ id: v.string() })]),
	}),
});

// Invitation pricing tiers resolve private Stripe coupon IDs server-side from
// `config :dhc, :membership_tier_coupons`. The coupons are durable account
// configuration, like membership prices: create them when missing and never
// delete them after a test run.
const coachCouponId = process.env.STRIPE_COACH_COUPON_ID || "DHC_COACH_TIER";
const studentCouponId =
	process.env.STRIPE_STUDENT_COUPON_ID || "DHC_STUDENT_TIER";

// Stripe resource references arrive as either bare ids or expanded objects.
function stripeReferenceId(reference: StripeReference): string | undefined {
	const stringReference = v.safeParse(v.string(), reference);
	if (stringReference.success) return stringReference.output;

	const objectReference = v.safeParse(v.object({ id: v.string() }), reference);
	return objectReference.success ? objectReference.output.id : undefined;
}

function getStripeFrame(page: Page) {
	return page.locator(".__PrivateStripeElement").frameLocator("iframe");
}

function pricingRow(page: Page, label: string) {
	return page.getByText(label, { exact: true }).locator("..");
}

function currencyValues(value: string | null) {
	return Array.from(value?.matchAll(/€\s?([\d,]+(?:\.\d{2})?)/g) ?? []).map(
		([, amount]) => Number(amount.replaceAll(",", "")),
	);
}

async function monthlyProductId(): Promise<string> {
	const prices = await stripeClient.prices.list({
		lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME],
		active: true,
		limit: 1,
	});
	const price = prices.data[0];
	if (!price) {
		throw new Error(
			`No active price found for lookup key ${MEMBERSHIP_FEE_LOOKUP_NAME}`,
		);
	}
	const product = stripeReferenceId(price.product);
	if (!product) {
		throw new Error("The monthly membership price has no product");
	}
	return product;
}

async function retrieveCoupon(couponId: string) {
	try {
		return await stripeClient.coupons.retrieve(couponId);
	} catch (error) {
		const parsed = v.safeParse(
			v.object({ code: v.optional(v.string()) }),
			error,
		);
		if (parsed.success && parsed.output.code === "resource_missing") {
			return undefined;
		}
		throw error;
	}
}

async function ensureTierCoupons() {
	if (!(await retrieveCoupon(coachCouponId))) {
		await stripeClient.coupons.create({
			id: coachCouponId,
			name: "Coach membership tier",
			percent_off: 100,
			duration: "forever",
		});
	}

	if (!(await retrieveCoupon(studentCouponId))) {
		const productId = await monthlyProductId();
		await stripeClient.coupons.create({
			id: studentCouponId,
			name: "Student membership tier",
			percent_off: 20,
			duration: "forever",
			applies_to: { products: [productId] },
		});
	}
}

// Stripe omits coupon product eligibility from retrieve responses in the API
// version used here. Validate immutable discount values at setup; the pricing
// and subscription assertions below verify the domain-owned tier scope.
async function assertTierCouponConfiguration() {
	const coach = await stripeClient.coupons.retrieve(coachCouponId);
	if (coach.duration !== "forever" || coach.percent_off !== 100) {
		throw new Error(
			`Coupon "${coachCouponId}" must be 100% off forever. Delete and recreate it in Stripe.`,
		);
	}

	const coupon = await stripeClient.coupons.retrieve(studentCouponId);
	if (coupon.duration !== "forever" || coupon.percent_off !== 20) {
		throw new Error(
			`Coupon "${studentCouponId}" must be 20% off forever. Delete and recreate it in Stripe.`,
		);
	}
}

test.beforeAll(async () => {
	await ensureTierCoupons();
	await assertTierCouponConfiguration();
});

async function walkToPayment(
	page: Page,
	invitation: InvitedUser,
	expectsPaymentElement = true,
) {
	await routeSuccessfulDiscordAcceptance(page, invitation.invitationId);
	await page.goto(`/members/signup/${invitation.invitationId}`);
	const verifyButton = page.getByRole("button", {
		name: /verify invitation/i,
	});
	await expect(verifyButton).toBeVisible();
	await page.waitForLoadState("networkidle");
	await fillInvitationCredentials(page, {
		email: invitation.email,
		dateOfBirth: invitation.date_of_birth.format("YYYY-MM-DD"),
	});
	await verifyButton.click();
	await page.getByRole("link", { name: "Continue to Discord" }).click();
	await expect(
		page.getByRole("heading", { name: "Discord verified" }),
	).toBeVisible();
	await page.getByRole("button", { name: "Continue to payment" }).click();
	await expect(page.getByLabel("Next of Kin", { exact: true })).toBeVisible();
	await expect(page.locator("#payment-element-state")).toHaveAttribute(
		"data-ready",
		"true",
	);
	if (expectsPaymentElement) {
		await expect(getStripeFrame(page).getByLabel("IBAN")).toBeVisible({
			timeout: 15_000,
		});
	} else {
		await expect(page.locator(".__PrivateStripeElement")).toHaveCount(0);
	}
}

async function fillNextOfKin(page: Page) {
	await page.getByLabel("Next of Kin", { exact: true }).fill("John Doe");
	const phoneInputField = page.getByLabel("Next of Kin Phone Number");
	await phoneInputField.pressSequentially("0838774532", { delay: 50 });
	await phoneInputField.press("Tab");
}

async function fillNextOfKinAndPayment(page: Page, invitation: InvitedUser) {
	await fillNextOfKin(page);

	const stripeFrame = getStripeFrame(page);
	await stripeFrame.getByLabel("IBAN").fill("IE29AIBK93115212345678");
	await stripeFrame.getByLabel("Email").fill(invitation.email);
	await stripeFrame.getByLabel("Full name").fill("John Doe");
	await stripeFrame.getByLabel("Address line 1").fill("123 Main Street");
	await stripeFrame.getByLabel("Address line 2").fill("Apt 4B");
	await stripeFrame.getByLabel("Country or region").selectOption("Ireland");
	await stripeFrame.getByLabel("City").fill("Dublin");
	await stripeFrame.getByLabel("Eircode").fill("K45 HR22");
	await stripeFrame.getByLabel("County").selectOption("Dublin");
	await expect(page.locator("#payment-element-state")).toHaveAttribute(
		"data-complete",
		"true",
	);
}

async function fetchPricing(
	request: APIRequestContext,
	invitationId: string,
): Promise<PricingDTO["data"]> {
	const response = await request.get(
		`${API_BASE_URL}/invitations/${invitationId}/pricing`,
	);
	expect(response.status()).toBe(200);
	return v.parse(PricingSchema, await response.json()).data;
}

function discountCouponIds(subscription: { discounts?: unknown[] }) {
	return (subscription.discounts ?? []).flatMap((discount) => {
		const parsed = v.safeParse(DiscountSchema, discount);
		if (!parsed.success) return [];
		const id = stripeReferenceId(parsed.output.source.coupon);
		return id ? [id] : [];
	});
}

function latestInvoiceAmountDue(subscription: { latest_invoice?: unknown }) {
	if (subscription.latest_invoice == null) {
		return undefined;
	}

	const parsed = v.safeParse(
		v.object({ amount_due: v.number() }),
		subscription.latest_invoice,
	);
	if (!parsed.success) {
		throw new Error(
			"latest_invoice was not expanded; include 'data.latest_invoice' in expand",
		);
	}
	return parsed.output.amount_due;
}

test.describe.configure({ timeout: 90_000 });

test("a student tier invitation completes signup with a discounted monthly fee", async ({
	page,
	request,
}) => {
	const invitation = await setupInvitedUser({ pricingTier: "student" });

	try {
		const pricing = await fetchPricing(request, invitation.invitationId);

		const fullFeeCents = pricing.monthlyFee.amount;
		const discountedFee = pricing.discountedMonthlyFee;
		if (!discountedFee) {
			throw new Error("Student tier pricing has no discounted monthly fee");
		}
		const discountedFeeCents = discountedFee.amount;
		expect(discountedFeeCents).toBeLessThan(fullFeeCents);

		await walkToPayment(page, invitation);

		const monthlyRow = pricingRow(page, "Then monthly");
		const [shownDiscounted, shownOriginal] = currencyValues(
			await monthlyRow.textContent(),
		);
		expect(shownOriginal).toBe(fullFeeCents / 100);
		expect(shownDiscounted).toBe(discountedFeeCents / 100);

		// The annual fee stays full price — the student coupon is scoped to
		// the monthly product only.
		const annualRowValues = currencyValues(
			await pricingRow(page, "Then annually").textContent(),
		);
		expect(annualRowValues).toEqual([pricing.annualFee.amount / 100]);

		await expect(
			page.getByText(`Discount applied: ${pricing.discountPercentage}% off`),
		).toBeVisible();

		await fillNextOfKinAndPayment(page, invitation);
		await page.getByRole("button", { name: /sign up/i }).click();
		await expect(page.getByText("Membership created")).toBeVisible({
			timeout: 30_000,
		});

		// The accepted member carries the server-selected discount into Stripe:
		// the monthly subscription has the private student coupon attached; the
		// annual one does not.
		const customers = await stripeClient.customers.list({
			email: invitation.email,
			limit: 2,
		});
		expect(customers.data).toHaveLength(1);

		const monthlyPrices = await stripeClient.prices.list({
			lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME],
			active: true,
			limit: 1,
		});
		const monthlyPriceId = monthlyPrices.data[0]?.id;

		const subscriptions = await stripeClient.subscriptions.list({
			customer: customers.data[0].id,
			status: "all",
			limit: 10,
			expand: ["data.discounts", "data.latest_invoice"],
		});
		expect(subscriptions.data).toHaveLength(2);

		for (const subscription of subscriptions.data) {
			const isMonthlySubscription =
				subscription.items.data[0]?.price?.id === monthlyPriceId;
			const ids = discountCouponIds(subscription);

			if (isMonthlySubscription) {
				expect(ids).toContain(studentCouponId);
			} else {
				expect(ids).not.toContain(studentCouponId);
			}
		}
	} finally {
		await invitation.cleanUp();
	}
});

test("a coach tier invitation completes signup with complimentary membership", async ({
	page,
	request,
}) => {
	const invitation = await setupInvitedUser({ pricingTier: "coach" });

	try {
		const pricing = await fetchPricing(request, invitation.invitationId);
		expect(pricing.proratedPrice.amount).toBe(0);
		expect(pricing.discountPercentage).toBe(100);

		await walkToPayment(page, invitation, false);

		await expect(page.getByText("Due today", { exact: true })).toHaveCount(0);
		await expect(page.getByText("Have a promotional code?")).toHaveCount(0);

		await fillNextOfKin(page);
		await page.getByRole("button", { name: "Complete signup" }).click();
		await expect(page.getByText("Membership created")).toBeVisible({
			timeout: 30_000,
		});

		// Both memberships invoice at zero and carry the private coach coupon.
		const customers = await stripeClient.customers.list({
			email: invitation.email,
			limit: 2,
		});
		expect(customers.data).toHaveLength(1);

		const subscriptions = await stripeClient.subscriptions.list({
			customer: customers.data[0].id,
			status: "all",
			limit: 10,
			expand: ["data.discounts", "data.latest_invoice"],
		});
		expect(subscriptions.data).toHaveLength(2);

		for (const subscription of subscriptions.data) {
			expect(discountCouponIds(subscription)).toContain(coachCouponId);
			const amountDue = latestInvoiceAmountDue(subscription);
			if (amountDue !== undefined) expect(amountDue).toBe(0);
		}
	} finally {
		await invitation.cleanUp();
	}
});
