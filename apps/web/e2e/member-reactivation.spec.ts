import { expect, test, type Page } from "@playwright/test";
import {
	createMember,
	createStripeCustomerWithSavedSepaMethod,
} from "./setupFunctions";
import { loginAsUser } from "./auth";
import { gotoHydrated } from "./hydration";

// ALE-252: committee operators reactivate an inactive member end-to-end from
// the dashboard. The fixture member has a Stripe customer with a saved SEPA
// method but no subscription (inactive), so the flow previews the saved
// method and mints fresh monthly + annual subscriptions against it.
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

	test.beforeAll(async () => {
		adminEmail = `reactivate-admin-${Date.now()}@test.com`;
		memberEmail = `reactivate-member-${Date.now()}@test.com`;

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
	});

	test.afterAll(async () => {
		await Promise.all([
			adminData?.cleanUp(),
			memberData?.cleanUp(),
			plainMemberData?.cleanUp(),
			coordinatorData?.cleanUp(),
			sepaCustomer?.cleanUp(),
		]);
	});

	function directoryEntry(page: Page) {
		// Desktop renders table rows, narrow viewports render cards; both carry
		// a link labelled with the member's email.
		return page
			.getByRole("row")
			.filter({ has: page.getByRole("link", { name: memberEmail }) })
			.or(
				page
					.getByRole("article")
					.filter({ has: page.getByRole("link", { name: memberEmail }) }),
			)
			.first();
	}

	async function openReactivationFromDirectory(page: Page) {
		await gotoHydrated(page, "/dashboard/members/directory");
		const entry = directoryEntry(page);
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

		const entry = directoryEntry(page);
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

		const entry = directoryEntry(page);
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
		const dialog = await openReactivationFromDirectory(page);

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
		expect(amountsBody.data.monthlyFee.amount).toBeGreaterThan(0);
		expect(amountsBody.data.annualFee.amount).toBeGreaterThan(0);

		await expect(dialog.getByText("Due today")).toBeVisible();
		await expect(dialog.getByText(/monthly membership/i).first()).toBeVisible();
		await expect(dialog.getByText(/annual membership/i).first()).toBeVisible();
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
		await expect(directoryEntry(page)).toContainText(/active/i);

		// The detail page agrees after reconciliation.
		await gotoHydrated(page, `/dashboard/members/${memberData.userId}`);
		await expect(
			page.getByLabel("Membership settings").getByText(/active/i),
		).toBeVisible();
		await expect(
			page.getByRole("button", { name: /reactivate membership/i }),
		).toHaveCount(0);
	});
});
