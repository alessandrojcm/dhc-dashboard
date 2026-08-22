import { expect, test, type Page } from "@playwright/test";
import {
	createMember,
	createStripeCustomerWithSavedSepaMethod,
	stripeClient,
} from "./setupFunctions";
import { loginAsUser } from "./auth";
import { gotoHydrated } from "./hydration";
import {
	ANNUAL_FEE_LOOKUP,
	MEMBERSHIP_FEE_LOOKUP_NAME,
} from "../src/lib/server/constants";

// ALE-252: committee operators reactivate an inactive member end-to-end from
// the dashboard. The fixture members have a Stripe customer with a saved SEPA
// method but no subscription (inactive), so the flow previews the saved
// method and mints fresh monthly + annual subscriptions against it.
// ALE-253 adds a second fixture member for the deferred-annual flow.
test.describe("Member reactivation", () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let adminEmail: string;
	let memberData: Awaited<ReturnType<typeof createMember>>;
	let memberEmail: string;
	let plainMemberData: Awaited<ReturnType<typeof createMember>>;
	let coordinatorData: Awaited<ReturnType<typeof createMember>>;
	let sepaCustomer: Awaited<
		ReturnType<typeof createStripeCustomerWithSavedSepaMethod>
	>;
	let deferredEmail: string;
	let deferredMemberData: Awaited<ReturnType<typeof createMember>>;
	let deferredSepaCustomer: Awaited<
		ReturnType<typeof createStripeCustomerWithSavedSepaMethod>
	>;

	test.beforeAll(async () => {
		adminEmail = `reactivate-admin-${Date.now()}@test.com`;
		memberEmail = `reactivate-member-${Date.now()}@test.com`;
		deferredEmail = `reactivate-deferred-${Date.now()}@test.com`;

		adminData = await createMember({
			email: adminEmail,
			roles: new Set(["admin", "member"]),
		});
		sepaCustomer = await createStripeCustomerWithSavedSepaMethod(memberEmail);
		memberData = await createMember({
			email: memberEmail,
			customerId: sepaCustomer.customerId,
			// Lapsed member: no live subscription, locally flagged inactive.
			isActive: false,
		});
		plainMemberData = await createMember({
			email: `reactivate-self-${Date.now()}@test.com`,
		});
		coordinatorData = await createMember({
			email: `reactivate-coord-${Date.now()}@test.com`,
			roles: new Set(["workshop_coordinator", "member"]),
		});
		deferredSepaCustomer =
			await createStripeCustomerWithSavedSepaMethod(deferredEmail);
		deferredMemberData = await createMember({
			email: deferredEmail,
			customerId: deferredSepaCustomer.customerId,
			isActive: false,
		});
	});

	test.afterAll(async () => {
		await Promise.all([
			adminData?.cleanUp(),
			memberData?.cleanUp(),
			plainMemberData?.cleanUp(),
			coordinatorData?.cleanUp(),
			sepaCustomer?.cleanUp(),
			deferredMemberData?.cleanUp(),
			deferredSepaCustomer?.cleanUp(),
		]);
	});

	function directoryEntry(page: Page, email: string) {
		// Desktop renders table rows, narrow viewports render cards; both carry
		// a link labelled with the member's email.
		return page
			.getByRole("row")
			.filter({ has: page.getByRole("link", { name: email }) })
			.or(
				page
					.getByRole("article")
					.filter({ has: page.getByRole("link", { name: email }) }),
			)
			.first();
	}

	async function openReactivationFromDirectory(page: Page, email: string) {
		await gotoHydrated(page, "/dashboard/members/directory");
		const entry = directoryEntry(page, email);
		await expect(entry).toBeVisible();
		await entry.getByRole("button", { name: /reactivate/i }).click();
		return page.getByRole("dialog");
	}

	test("admin sees the reactivate row action for inactive members only", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, adminEmail);
		await gotoHydrated(page, "/dashboard/members/directory");

		const entry = directoryEntry(page, memberEmail);
		await expect(entry).toBeVisible();
		// Inactive member with billing authority → action visible…
		await expect(
			entry.getByRole("button", { name: /reactivate/i }),
		).toBeVisible();

		// …but active members never offer reactivation.
		const adminEntry = page
			.getByRole("row")
			.filter({ has: page.getByRole("link", { name: adminEmail }) })
			.or(
				page
					.getByRole("article")
					.filter({ has: page.getByRole("link", { name: adminEmail }) }),
			)
			.first();
		await expect(adminEntry).toBeVisible();
		await expect(
			adminEntry.getByRole("button", { name: /reactivate/i }),
		).toHaveCount(0);
	});

	test("non-minting coordinator does not see the reactivate action", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, coordinatorData.email);
		await gotoHydrated(page, "/dashboard/members/directory");

		const entry = directoryEntry(page, memberEmail);
		await expect(entry).toBeVisible();
		await expect(
			entry.getByRole("button", { name: /reactivate/i }),
		).toHaveCount(0);

		// The detail page gate mirrors the minting pipeline too.
		await gotoHydrated(page, `/dashboard/members/${memberData.userId}`);
		await expect(
			page.getByRole("button", { name: /reactivate membership/i }),
		).toHaveCount(0);
	});

	test("member does not see the reactivate control on their own profile", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, plainMemberData.email);
		await gotoHydrated(page, `/dashboard/members/${plainMemberData.userId}`);

		await expect(
			page.getByRole("button", { name: /reactivate membership/i }),
		).toHaveCount(0);
	});

	test("admin reactivates from the directory row action and the views reconcile", async ({
		page,
		context,
	}) => {
		test.setTimeout(120_000);
		await loginAsUser(context, adminEmail);

		const amountsResponse = page.waitForResponse(
			(response) =>
				response.request().method() === "GET" &&
				response
					.url()
					.includes(
						`/members/${memberData.userId}/membership/reactivation-preview/amounts`,
					),
		);
		const dialog = await openReactivationFromDirectory(page, memberEmail);

		// The saved SEPA method is shown BEFORE any charge happens.
		await expect(dialog.getByText(/saved SEPA direct debit/i)).toBeVisible();
		await expect(dialog.getByText(/ending in 5678/i)).toBeVisible();

		// ALE-254: before confirming, the operator sees the Stripe-computed
		// amounts for the selected start date — never client-side math.
		const amounts = await amountsResponse;
		expect(amounts.status()).toBe(200);
		const amountsBody = await amounts.json();
		expect(amountsBody.data.dueToday.amount).toBeGreaterThan(0);
		expect(amountsBody.data.dueToday.currency).toBe("EUR");
		expect(amountsBody.data.proratedMonthlyPrice.amount).toBeGreaterThan(0);
		expect(amountsBody.data.proratedAnnualPrice.amount).toBeGreaterThan(0);
		expect(amountsBody.data.monthlyFee.amount).toBeGreaterThan(0);
		expect(amountsBody.data.annualFee.amount).toBeGreaterThan(0);

		await expect(dialog.getByText("Due today")).toBeVisible();
		await expect(
			dialog.getByText(/for this month.*for this year/i),
		).toBeVisible();
		await expect(dialog.getByText("Then monthly")).toBeVisible();
		await expect(dialog.getByText("Then annually")).toBeVisible();
		await expect(
			dialog.getByTestId("reactivation-amounts").getByText(/€\d/).first(),
		).toBeVisible();

		const reactivateResponse = page.waitForResponse(
			(response) =>
				response.request().method() === "POST" &&
				response
					.url()
					.endsWith(`/members/${memberData.userId}/membership/reactivate`),
		);
		await dialog.getByRole("button", { name: "Reactivate membership" }).click();
		expect((await reactivateResponse).status()).toBe(200);

		// SEPA settles asynchronously: pending settlement is reported as its
		// own outcome, distinct from a completed activation. The modal closes
		// and the toast reports the outcome.
		await expect(dialog).toBeHidden();
		await expect(
			page
				.locator("[data-sonner-toast]")
				.getByText(/awaiting bank confirmation|membership reactivated/i),
		).toBeVisible();

		// Success reconciles list/detail/analytics without a reload: the row
		// no longer reads inactive.
		await expect(directoryEntry(page, memberEmail)).toContainText(/active/i);

		// The detail page agrees after reconciliation.
		await gotoHydrated(page, `/dashboard/members/${memberData.userId}`);
		await expect(
			page.getByLabel("Membership settings").getByText(/active/i),
		).toBeVisible();
		await expect(
			page.getByRole("button", { name: /reactivate membership/i }),
		).toHaveCount(0);
	});

	// ALE-253: the operator can instead defer the annual fee — the annual
	// subscription is created immediately but trialing until next January's
	// anchor, so nothing annual is charged today. Verified against the real
	// Stripe test API.
	test("admin defers the annual fee to next January and Stripe starts a trialing annual", async ({
		page,
		context,
	}) => {
		test.setTimeout(120_000);
		// The operator holds billing authority; the inactive fixture member is
		// only the TARGET of the reactivation (inactive principals cannot sign
		// in).
		await loginAsUser(context, adminEmail);

		const dialog = await openReactivationFromDirectory(page, deferredEmail);

		// The saved SEPA method is shown before any charge happens.
		await expect(dialog.getByText(/saved SEPA direct debit/i)).toBeVisible();

		// Choosing deferral refetches amounts keyed by the deferred mode…
		const deferredAmountsResponse = page.waitForResponse(
			(response) =>
				response.request().method() === "GET" &&
				response
					.url()
					.includes(
						`/members/${deferredMemberData.userId}/membership/reactivation-preview/amounts`,
					) &&
				response
					.url()
					.includes(
						encodeURIComponent("annualFeeMode") + "=deferred_next_year",
					),
		);
		await dialog
			.getByRole("radio", { name: /defer until next january/i })
			.click();
		const deferredAmounts = await deferredAmountsResponse;
		expect(deferredAmounts.status()).toBe(200);
		const deferredAmountsBody = await deferredAmounts.json();
		expect(
			deferredAmountsBody.data.proratedMonthlyPrice.amount,
		).toBeGreaterThan(0);
		expect(deferredAmountsBody.data.proratedAnnualPrice.amount).toBe(0);

		// …and the recurring annual line is labelled for its January billing.
		await expect(dialog.getByText("Then annually")).toBeVisible();
		// Nothing annual is due today in this mode.
		await expect(dialog.getByText("Due today")).toBeVisible();

		const reactivateResponse = page.waitForResponse(
			(response) =>
				response.request().method() === "POST" &&
				response
					.url()
					.endsWith(
						`/members/${deferredMemberData.userId}/membership/reactivate`,
					),
		);
		await dialog.getByRole("button", { name: "Reactivate membership" }).click();
		const response = await reactivateResponse;
		expect(response.status()).toBe(200);

		// The command received the operator's chosen mode.
		expect(response.request().postDataJSON()).toMatchObject({
			startDate: expect.any(String),
			annualFeeMode: "deferred_next_year",
		});

		await expect(dialog).toBeHidden();
		await expect(
			page
				.locator("[data-sonner-toast]")
				.getByText(/awaiting bank confirmation|membership reactivated/i),
		).toBeVisible();

		// Real Stripe state: monthly covers immediately (or while SEPA
		// settles), annual sits trialing until next January 7 at midnight UTC —
		// the deterministic anchor idempotent retries rely on.
		const priceLookupByPriceId = new Map<string, string>();
		for (const lookup of [ANNUAL_FEE_LOOKUP, MEMBERSHIP_FEE_LOOKUP_NAME]) {
			const found = await stripeClient.prices.list({
				lookup_keys: [lookup],
				active: true,
				limit: 1,
			});
			if (found.data[0]) {
				priceLookupByPriceId.set(found.data[0].id, lookup);
			}
		}

		const subscriptions = await stripeClient.subscriptions.list({
			customer: deferredSepaCustomer.customerId,
			status: "all",
			limit: 10,
		});
		expect(subscriptions.data.length).toBe(2);

		const now = new Date();
		let candidate = Date.UTC(now.getUTCFullYear(), 0, 7);
		if (candidate <= now.getTime()) {
			candidate = Date.UTC(now.getUTCFullYear() + 1, 0, 7);
		}

		for (const subscription of subscriptions.data) {
			const lookup = priceLookupByPriceId.get(
				subscription.items.data[0]?.price.id ?? "",
			);

			if (lookup === ANNUAL_FEE_LOOKUP) {
				expect(subscription.status).toBe("trialing");
				expect(subscription.trial_end).toBe(Math.floor(candidate / 1000));
			} else if (lookup === MEMBERSHIP_FEE_LOOKUP_NAME) {
				expect(["active", "trialing"]).toContain(subscription.status);
			} else {
				throw new Error(
					`Unexpected non-membership subscription ${subscription.id}`,
				);
			}
		}

		// The views reconcile to active without a reload.
		await expect(directoryEntry(page, deferredEmail)).toContainText(/active/i);
	});
});
