import { faker } from "@faker-js/faker";
import { type Browser, expect, type Page, test } from "@playwright/test";
import { loginAsUser } from "./auth";
import { stubEmbeddedCheckout } from "./beginners-workshop-checkout";
import {
	deleteE2EFixture,
	deleteE2EFixtureUnlessReferenced,
	seedE2EScenario,
} from "./e2eApi";
import { gotoHydrated } from "./hydration";
import { stripeClient } from "./setupFunctions";

// ALE-426: the refund module's money commands (ALE-421) submitted end to
// end — remote form, preflight, server-side Valibot, Phoenix — in both
// refund scopes: the Waitlist tab's person and the Manage page's workshop.
//
// Money that must really refund is a succeeded test-mode PaymentIntent
// this spec creates; the harness links it to an imported workshop credit
// or names it on a completed Checkout Session. Money that must fail to
// refund is either a payment the harness made up (`pi_e2e_<id>`, which
// Stripe refuses) or a PaymentIntent the spec already refunded in Stripe.
// Stripe answers through the refund worker after the command returns, so
// a failed refund is waited for with a reload.

const WAITLIST_PATH = "/dashboard/beginners-workshop/waitlist";

const tag = `${Date.now()}-${faker.string.alphanumeric(6).toLowerCase()}`;

// Fixtures the run seeded, torn down in `afterAll` whatever the tests did.
// A person the app deleted is dropped from the list once it has.
const waitlistIds = new Set<string>();
const memberIds: string[] = [];
const paymentIntentIds: string[] = [];

async function seedPerson(firstName: string, initialRegistrationDate: string) {
	const person = await seedE2EScenario("waitlist", {
		email: `bw-money-${firstName.toLowerCase()}-${tag}@example.com`,
		firstName,
		lastName: "Money",
		initialRegistrationDate,
	});
	waitlistIds.add(person.waitlistId);
	return { ...person, name: `${firstName} Money` };
}

/** A succeeded test-mode card payment; `paymentMethod` picks its refund behaviour. */
async function createPayment(
	amount: number,
	paymentMethod = "pm_card_visa",
): Promise<string> {
	const intent = await stripeClient.paymentIntents.create({
		amount,
		currency: "eur",
		payment_method: paymentMethod,
		payment_method_types: ["card"],
		confirm: true,
		description: `ALE-426 E2E ${tag}`,
	});
	paymentIntentIds.push(intent.id);
	expect(intent.status).toBe("succeeded");
	return intent.id;
}

/** A Waitlist person holding workshop credit linked to a real €35 payment. */
async function seedCreditHolder(
	firstName: string,
	coordinatorId: string,
	paymentIntentId?: string,
) {
	const person = await seedPerson(firstName, "2024-01-01T09:00:00Z");
	const fee = await seedE2EScenario("beginnersWorkshopCarriedFee", {
		waitlistId: person.waitlistId,
		paymentIntentId: paymentIntentId ?? (await createPayment(3500)),
		actorId: coordinatorId,
	});
	expect(fee).toMatchObject({ status: "held", amountCents: 3500 });
	return person;
}

/**
 * A Stripe-paid workshop place: a workshop of one seat, the Batch that
 * offers it to the person (seeded older than anyone else in the run), the
 * Seat Hold the Intake page takes through a real test-mode Checkout
 * Session, and its completion naming `paymentIntentId`.
 */
async function seedPaidPlace(
	browser: Browser,
	coordinatorId: string,
	firstName: string,
	registeredAt: string,
	paymentIntentId?: string,
) {
	const person = await seedPerson(firstName, registeredAt);
	const workshop = await seedE2EScenario("beginnersWorkshop", {
		actorId: coordinatorId,
		venue: `Money Hall ${firstName}`,
	});
	const batch = await seedE2EScenario("beginnersWorkshopBatch", {
		workshopId: workshop.workshopId,
	});
	expect(batch.contactedWaitlistIds).toEqual([person.waitlistId]);
	const link = await seedE2EScenario("beginnersWorkshopIntakeLink", {
		waitlistId: person.waitlistId,
	});

	const context = await browser.newContext();
	let cleanupCheckout = async () => {};
	try {
		const personPage = await context.newPage();
		cleanupCheckout = await stubEmbeddedCheckout(personPage);
		await gotoHydrated(personPage, link.path);
		await expect(
			personPage.getByRole("button", { name: "Complete test payment" }),
		).toBeVisible();
		const payment = await seedE2EScenario("beginnersWorkshopPayment", {
			waitlistId: person.waitlistId,
			paymentIntentId,
		});
		expect(payment.outcome).toBe("paid");
	} finally {
		try {
			await cleanupCheckout();
		} finally {
			await context.close();
		}
	}
	return { person, workshopId: workshop.workshopId };
}

/** The person's Waitlist row: the desktop table row or the mobile card. */
function waitlistRow(page: Page, name: string) {
	const waitlist = page.getByRole("region", { name: "Waitlist", exact: true });
	return waitlist
		.getByRole("row")
		.filter({ hasText: name })
		.or(waitlist.getByRole("listitem").filter({ hasText: name }));
}

async function openWaitlist(page: Page, search: string, status?: "removed") {
	const query = new URLSearchParams({ q: search });
	if (status) query.set("status", status);
	await gotoHydrated(page, `${WAITLIST_PATH}?${query}`);
}

/** Opens the person's workshop credit panel on the Waitlist tab. */
async function openCreditPanel(page: Page, name: string, timeout?: number) {
	await waitlistRow(page, name)
		.getByRole("button", { name: "Expand row" })
		.click({ timeout });
	const credit = page.getByTestId("waitlist-carried-fee");
	await credit
		.getByRole("button", { name: "Refund or link payment…" })
		.click({ timeout });
	return credit;
}

/** Reloads the Waitlist until the person's credit shows a failed refund. */
async function waitForPersonFailedRefund(
	page: Page,
	search: string,
	name: string,
) {
	await expect(async () => {
		await openWaitlist(page, search);
		const credit = await openCreditPanel(page, name, 5_000);
		await expect(credit.getByTestId("failed-refund")).toBeVisible({
			timeout: 2_000,
		});
	}).toPass({ timeout: 30_000 });
	return page.getByTestId("waitlist-carried-fee").getByTestId("failed-refund");
}

async function openConsole(page: Page, workshopId: string) {
	await gotoHydrated(
		page,
		`/dashboard/beginners-workshop/workshops/${workshopId}`,
	);
}

/** Reloads the Manage page until Needs attention lists a failed refund. */
async function waitForConsoleFailedRefund(page: Page, workshopId: string) {
	const failed = page
		.getByRole("region", { name: "Needs attention" })
		.getByTestId("failed-refund");
	await expect(async () => {
		await openConsole(page, workshopId);
		await expect(failed).toBeVisible({ timeout: 2_000 });
	}).toPass({ timeout: 30_000 });
	return failed;
}

/** Withdraws a paid person from the Manage page, choosing to refund them. */
async function withdrawWithRefund(page: Page, name: string, amount: string) {
	await page
		.getByRole("region", { name: "Confirmed places" })
		.getByRole("button", { name: `${name} — Paid` })
		.click();
	await page
		.getByTestId("intake-detail")
		.getByRole("button", { name: "Withdraw…" })
		.click();
	const dialog = page.getByRole("dialog", {
		name: `Withdraw ${name} from the Waitlist`,
	});
	await expect(dialog.getByText("What happens to their fee?")).toBeVisible();
	await dialog
		.getByRole("radio", { name: new RegExp(`Refund ${amount}`) })
		.click();
	await dialog.getByRole("button", { name: "Withdraw", exact: true }).click();
	await expect(page.getByText("Withdrawn from the Waitlist")).toBeVisible();
	await expect(dialog).toHaveCount(0);
	await page.keyboard.press("Escape");
}

test.describe("Beginners' Workshop money", () => {
	let coordinatorEmail: string;
	let coordinatorId: string;

	test.beforeAll(async () => {
		const coordinator = await seedE2EScenario("member", {
			email: `bw-money-coordinator-${tag}@test.com`,
			roles: ["beginners_coordinator", "member"],
			firstName: "Money",
			lastName: `Coordinator${faker.string.alpha(6)}`,
		});
		memberIds.push(coordinator.userId);
		coordinatorEmail = coordinator.email;
		coordinatorId = coordinator.memberId;
	});

	test.beforeEach(async ({ context, page }) => {
		// The Waitlist scrolls inside its own panel, between a sticky header
		// and footer; a host-sized window can leave its rows under them.
		await page.setViewportSize({ width: 1280, height: 900 });
		await loginAsUser(context, coordinatorEmail);
	});

	test.afterAll(async () => {
		for (const waitlistId of waitlistIds)
			await deleteE2EFixture("waitlist", waitlistId);
		// The coordinator scheduled workshops, so it usually stays.
		for (const memberId of memberIds)
			await deleteE2EFixtureUnlessReferenced("member", memberId);
		// A payment the app forfeited (or never refunded) is refunded here.
		for (const id of paymentIntentIds) {
			const refunds = await stripeClient.refunds.list({ payment_intent: id });
			if (refunds.data.length === 0)
				await stripeClient.refunds.create({ payment_intent: id });
		}
	});

	test("Waitlist tab: Withdraw asks about the credit up front, and forfeiting it updates the list", async ({
		page,
	}) => {
		const first = `Forfeit${faker.string.alpha(8)}`;
		const person = await seedCreditHolder(first, coordinatorId);

		await openWaitlist(page, first);
		const row = waitlistRow(page, person.name);
		await expect(row).toContainText("Waiting · Workshop credit");
		await row
			.getByRole("button", { name: "Withdraw from the Waitlist" })
			.click();

		const dialog = page.getByRole("dialog", {
			name: `Withdraw ${person.name} from the Waitlist`,
		});
		await expect(
			dialog.getByText("What happens to their workshop credit?"),
		).toBeVisible();
		await expect(
			dialog.getByText("Refund their workshop credit: €35.00"),
		).toBeVisible();
		const submit = dialog.getByRole("button", {
			name: "Withdraw",
			exact: true,
		});
		await expect(submit).toBeDisabled();
		await dialog.getByRole("radio", { name: /Keep the payment/ }).click();
		await submit.click();

		await expect(page.getByText("Withdrawn from the Waitlist")).toBeVisible();
		await expect(dialog).toHaveCount(0);
		// The person-scope success invalidated the Waitlist page: no reload.
		await expect(row).toHaveCount(0);

		await page.getByRole("radio", { name: "Removed" }).click();
		await expect(row).toContainText(/Removed \d{2}\/\d{2}\/\d{4}/);
		await expect(row).not.toContainText("Workshop credit");
	});

	test("Waitlist tab: a Withdraw from a stale read is asked the choice after Phoenix refuses", async ({
		page,
	}) => {
		const first = `Stale${faker.string.alpha(8)}`;
		const person = await seedPerson(first, "2024-01-02T09:00:00Z");

		await openWaitlist(page, first);
		const row = waitlistRow(page, person.name);
		await expect(row).toContainText("Waiting");
		await expect(row).not.toContainText("Workshop credit");

		// Credit arrives after the page read the person: Phoenix knows, the page does not.
		await seedE2EScenario("beginnersWorkshopCarriedFee", {
			waitlistId: person.waitlistId,
		});

		await row
			.getByRole("button", { name: "Withdraw from the Waitlist" })
			.click();
		const dialog = page.getByRole("dialog", {
			name: `Withdraw ${person.name} from the Waitlist`,
		});
		await expect(dialog.getByRole("radio")).toHaveCount(0);
		await dialog.getByRole("button", { name: "Withdraw", exact: true }).click();

		await expect(
			dialog.getByText("Choose whether to refund or forfeit their fee"),
		).toBeVisible();
		await expect(dialog.getByText("What happens to their fee?")).toBeVisible();
		await expect(dialog.getByText("Refund in full")).toBeVisible();
		await dialog.getByRole("radio", { name: /Keep the payment/ }).click();
		await dialog.getByRole("button", { name: "Withdraw", exact: true }).click();

		await expect(page.getByText("Withdrawn from the Waitlist")).toBeVisible();
		await expect(row).toHaveCount(0);
	});

	test("Waitlist tab: Delete asks about the credit, refunds it and the person is gone", async ({
		page,
	}) => {
		const first = `Delete${faker.string.alpha(8)}`;
		const person = await seedCreditHolder(first, coordinatorId);

		await openWaitlist(page, first);
		const row = waitlistRow(page, person.name);
		await row.getByRole("button", { name: "Delete this person" }).click();

		const dialog = page.getByRole("dialog", { name: `Delete ${person.name}` });
		await expect(dialog).toContainText("Nobody is emailed.");
		const submit = dialog.getByRole("button", { name: "Delete", exact: true });
		await expect(submit).toBeDisabled();
		await dialog
			.getByRole("radio", { name: /Refund their workshop credit: €35\.00/ })
			.click();
		await submit.click();

		await expect(
			page.getByText(
				"Deleted. Their workshop places stay in the reports, anonymised",
			),
		).toBeVisible();
		waitlistIds.delete(person.waitlistId);
		await expect(row).toHaveCount(0);

		for (const status of [undefined, "removed"] as const) {
			await openWaitlist(page, first, status);
			// The empty state renders for both the table and the mobile list.
			await expect(
				page
					.getByText("Try a different search or status filter.")
					.filter({ visible: true }),
			).toBeVisible();
			await expect(row).toHaveCount(0);
		}
	});

	test("Waitlist tab: a failed credit refund is retried, then recorded as paid outside Stripe", async ({
		page,
	}) => {
		const first = `Owed${faker.string.alpha(8)}`;
		// Refunded in Stripe after it is linked, so the app's refund is refused.
		const paymentIntentId = await createPayment(3500);
		const person = await seedCreditHolder(
			first,
			coordinatorId,
			paymentIntentId,
		);
		await stripeClient.refunds.create({ payment_intent: paymentIntentId });

		await openWaitlist(page, first);
		let credit = await openCreditPanel(page, person.name);
		await credit.getByRole("button", { name: "Refund credit" }).click();
		const refund = page.getByRole("dialog", { name: "Refund credit" });
		await expect(refund).toContainText(
			"Refund €35.00 to the original payment? They will need to pay for their next workshop.",
		);
		await refund.getByRole("button", { name: "Refund", exact: true }).click();
		await expect(
			page.getByText(
				"Credit refund requested. They will need to pay for their next workshop",
			),
		).toBeVisible();

		// Stripe refuses it; the credit is available again and Phoenix
		// offers all three follow-ups.
		let failed = await waitForPersonFailedRefund(page, first, person.name);
		await expect(failed).toContainText("Refund of €35.00 failed");
		await expect(failed).toContainText(
			"Their workshop credit is available again.",
		);
		await expect(
			failed.getByRole("button", { name: "Record manual refund" }),
		).toBeVisible();
		await expect(
			failed.getByRole("button", { name: "Remove credit, keep payment" }),
		).toBeVisible();
		await failed.getByRole("button", { name: "Retry", exact: true }).click();
		await expect(page.getByText("Refund sent to Stripe again")).toBeVisible();

		// The retry is refused too; this time it is paid back by hand.
		failed = await waitForPersonFailedRefund(page, first, person.name);
		await failed.getByRole("button", { name: "Record manual refund" }).click();
		const manual = page.getByRole("dialog", { name: "Record manual refund" });
		await expect(manual).toContainText(
			"Record that you paid them €35.00 back outside Stripe. No email is sent.",
		);
		await manual
			.getByLabel("How did you pay them back? (optional)")
			.fill("Bank transfer");
		await manual.getByRole("button", { name: "Record refund" }).click();
		await expect(
			page.getByText("Manual refund recorded — no email sent"),
		).toBeVisible();

		credit = page.getByTestId("waitlist-carried-fee");
		await expect(credit.getByTestId("failed-refund")).toHaveCount(0);
		await expect(waitlistRow(page, person.name)).not.toContainText(
			"Workshop credit",
		);
	});

	test("Manage page: Withdraw with refund shows the refund as requested, not completed", async ({
		page,
		browser,
	}) => {
		const first = `Refund${faker.string.alpha(8)}`;
		// Stripe leaves this card's refunds pending, so it stays requested.
		const paymentIntentId = await createPayment(4000, "pm_card_pendingRefund");
		const { person, workshopId } = await seedPaidPlace(
			browser,
			coordinatorId,
			first,
			"1990-01-01T09:00:00Z",
			paymentIntentId,
		);

		await openConsole(page, workshopId);
		await withdrawWithRefund(page, person.name, "€40.00");

		// The workshop-scope success refreshed the Manage page's data.
		const out = page.getByRole("region", { name: "No longer attending" });
		const place = out.getByRole("button", {
			name: `${person.name} — Withdrawn`,
		});
		await expect(place).toContainText("Refund in progress");
		await expect(
			page.getByRole("region", { name: "Confirmed places" }),
		).toHaveCount(0);

		// After Stripe has answered, it is still a request, not a refund.
		await expect(async () => {
			const refunds = await stripeClient.refunds.list({
				payment_intent: paymentIntentId,
			});
			expect(refunds.data.map((refund) => refund.status)).toEqual(["pending"]);
		}).toPass({ timeout: 30_000 });
		await openConsole(page, workshopId);
		await expect(place).toContainText("Refund in progress");
		await expect(place).not.toContainText("Refunded");
	});

	test("Manage page: a failed refund is retried, then recorded as paid outside Stripe", async ({
		page,
		browser,
	}) => {
		const first = `Failed${faker.string.alpha(8)}`;
		// No PaymentIntent: the harness's made-up payment, which Stripe refuses to refund.
		const { person, workshopId } = await seedPaidPlace(
			browser,
			coordinatorId,
			first,
			"1990-01-02T09:00:00Z",
		);

		await openConsole(page, workshopId);
		await withdrawWithRefund(page, person.name, "€40.00");

		let failed = await waitForConsoleFailedRefund(page, workshopId);
		await expect(failed).toContainText(
			`Refund of €40.00 to ${person.name} failed`,
		);
		// A payment's own refund: Phoenix offers no forfeit.
		await expect(
			failed.getByRole("button", { name: "Record manual refund" }),
		).toBeVisible();
		await expect(
			failed.getByRole("button", { name: "Remove credit, keep payment" }),
		).toHaveCount(0);
		await failed.getByRole("button", { name: "Retry", exact: true }).click();
		await expect(page.getByText("Refund sent to Stripe again")).toBeVisible();

		failed = await waitForConsoleFailedRefund(page, workshopId);
		await failed.getByRole("button", { name: "Record manual refund" }).click();
		const manual = page.getByRole("dialog", { name: "Record manual refund" });
		await expect(manual).toContainText(
			`Record that you paid ${person.name} €40.00 back outside Stripe. No email is sent.`,
		);
		await manual.getByRole("button", { name: "Record refund" }).click();
		await expect(
			page.getByText("Manual refund recorded — no email sent"),
		).toBeVisible();

		await expect(failed).toHaveCount(0);
		await expect(
			page
				.getByRole("region", { name: "No longer attending" })
				.getByRole("button", { name: `${person.name} — Withdrawn` }),
		).toContainText("Refunded manually");
	});
});
