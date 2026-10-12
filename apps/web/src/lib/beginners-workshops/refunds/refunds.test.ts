import {
	beginnersWorkshopCarriedFeesShowQueryKey,
	beginnersWorkshopPeopleIndexQueryKey,
	beginnersWorkshopsConsoleQueryKey,
	waitlistEntriesQueryKey,
} from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { describe, expect, it, vi } from "vitest";
import { settleRefundCommand } from "./outcome.js";
import { personScope, staleQueries, workshopScope } from "./scope.js";
import {
	failedRefundText,
	refundChoiceLabel,
	refundChoiceQuestion,
	refundCommandDone,
	refundTimingHint,
	withdrawDescription,
} from "./wording.js";

describe("ALE-421: what each refund scope makes stale", () => {
	function seeded() {
		const queryClient = new QueryClient();
		const keys = {
			page: waitlistEntriesQueryKey({ query: { status: "waiting" } }),
			people: beginnersWorkshopPeopleIndexQueryKey({
				query: { waitlistIds: "a,b" },
			}),
			credit: beginnersWorkshopCarriedFeesShowQueryKey({
				path: { waitlistId: "a" },
			}),
			console: beginnersWorkshopsConsoleQueryKey({ path: { id: "w" } }),
		};
		for (const key of Object.values(keys)) queryClient.setQueryData(key, {});
		const stale = (key: readonly unknown[]) =>
			queryClient.getQueryState(key)?.isInvalidated;
		return { queryClient, keys, stale };
	}

	it("a person success invalidates the Waitlist pages, the people read and their credit", async () => {
		const { queryClient, keys, stale } = seeded();

		await settleRefundCommand(
			personScope("a"),
			"withdraw",
			{ ok: true, data: { outcome: "done" } },
			{ notify: { success: () => {} }, queryClient },
		);

		expect(stale(keys.page)).toBe(true);
		expect(stale(keys.people)).toBe(true);
		expect(stale(keys.credit)).toBe(true);
		expect(stale(keys.console)).toBe(false);
	});

	it("the console refreshes through its remote forms, so a workshop success names nothing", async () => {
		const { queryClient, keys, stale } = seeded();
		expect(staleQueries(workshopScope("w"))).toEqual([]);

		await settleRefundCommand(
			workshopScope("w"),
			"retry",
			{ ok: true, data: {} },
			{ notify: { success: () => {} }, queryClient },
		);

		for (const key of Object.values(keys)) expect(stale(key)).toBe(false);
	});

	it("a refusal is handed back, with nothing toasted or invalidated", async () => {
		const { queryClient, keys, stale } = seeded();
		const notify = { success: vi.fn() };

		await expect(
			settleRefundCommand(
				personScope("a"),
				"forfeit",
				{ ok: false, error: "This workshop credit is not held" },
				{ notify, queryClient },
			),
		).resolves.toEqual({
			ok: false,
			error: "This workshop credit is not held",
		});
		expect(notify.success).not.toHaveBeenCalled();
		expect(stale(keys.people)).toBe(false);
	});
});

describe("ALE-421: the outcome wording is one, for both scopes", () => {
	it("toasts the console's sentence, or that a repeat changed nothing", async () => {
		const notify = { success: vi.fn() };
		for (const scope of [workshopScope("w"), personScope("a")]) {
			await settleRefundCommand(
				scope,
				"refund_credit",
				{ ok: true, data: { outcome: "done" } },
				{ notify, queryClient: null },
			);
		}
		await settleRefundCommand(
			personScope("a"),
			"withdraw",
			{ ok: true, data: { outcome: "already_done" } },
			{ notify, queryClient: null },
		);

		expect(notify.success.mock.calls).toEqual([
			[
				"Credit refund requested. They will need to pay for their next workshop",
			],
			[
				"Credit refund requested. They will need to pay for their next workshop",
			],
			["Already done — nothing changed"],
		]);
	});

	it("words every follow-up and Delete", () => {
		expect(refundCommandDone("retry")).toBe("Refund sent to Stripe again");
		expect(refundCommandDone("manual")).toBe(
			"Manual refund recorded — no email sent",
		);
		expect(refundCommandDone("forfeit")).toBe(
			"Workshop credit removed; payment kept",
		);
		expect(refundCommandDone("delete_person")).toBe(
			"Deleted. Their workshop places stay in the reports, anonymised",
		);
	});

	it("says once that a withdrawn person can be restored for 3 months", () => {
		expect(withdrawDescription(workshopScope("w"))).toBe(
			"They leave the waitlist and this workshop. You can restore them to the waitlist for 3 months. Their payment will not be saved as workshop credit.",
		);
		expect(withdrawDescription(personScope("a"))).toBe(
			"They leave the waitlist and any current workshop place is closed. You can restore them to the waitlist for 3 months. Their payment will not be saved as workshop credit.",
		);
	});
});

describe("the refund-or-forfeit choice", () => {
	it("names the money a refund returns: what it originally took", () => {
		expect(
			refundChoiceLabel({
				source: "payment",
				amountCents: 4000,
				currency: "eur",
			}),
		).toBe("Refund €40.00");
		expect(
			refundChoiceLabel({
				source: "carried_fee",
				amountCents: 1250,
				currency: "gbp",
			}),
		).toBe("Refund their workshop credit: 12.50 GBP");
		expect(
			refundChoiceLabel({
				source: "carried_fee",
				amountCents: null,
				currency: null,
			}),
		).toBe("Refund their workshop credit in full");
	});

	it("asked only after a refusal, it knows no amount", () => {
		expect(refundChoiceLabel(null)).toBe("Refund in full");
		expect(refundChoiceQuestion(null)).toBe("What happens to their fee?");
		expect(
			refundChoiceQuestion({
				source: "carried_fee",
				amountCents: 3500,
				currency: "eur",
			}),
		).toBe("What happens to their workshop credit?");
	});

	it("words the days Phoenix counted, and nothing without them", () => {
		expect(refundTimingHint(null)).toBeNull();
		expect(refundTimingHint(7)).toBe(
			"Less than 7 days to go — there's no deadline; whether to refund is your call.",
		);
		expect(refundTimingHint(1)).toMatch(/^The workshop is tomorrow/);
		expect(refundTimingHint(0)).toMatch(/^The workshop is today/);
	});
});

describe("a failed refund", () => {
	const refund = {
		amountCents: 4000,
		currency: "eur",
		reason: "carried_fee_refunded",
		carriedFee: true,
	};

	it("offers Forfeit in its words only when Phoenix does", () => {
		expect(
			failedRefundText(refund, ["retry", "manual", "forfeit"], "Dara"),
		).toBe(
			"Refund of €40.00 to Dara failed (their workshop credit). Their workshop credit is available again. Retry the refund, record a refund paid outside the app, or keep the payment and remove the credit.",
		);
		expect(failedRefundText(refund, ["retry", "manual"], "Dara")).toBe(
			"Refund of €40.00 to Dara failed (their workshop credit). They have since paid or received another workshop credit, so this payment is still owed back. Retry the refund or record a refund paid outside the app.",
		);
	});

	it("a payment's own refund is retried or recorded", () => {
		expect(
			failedRefundText(
				{ ...refund, reason: "paid_after_close", carriedFee: false },
				["retry", "manual"],
				"Dara",
			),
		).toBe(
			"Refund of €40.00 to Dara failed (they paid after their place was closed). Retry the refund or record a refund paid outside the app.",
		);
	});

	it("on the Waitlist tab names Stripe's reason and nobody", () => {
		expect(
			failedRefundText(
				{ ...refund, lastError: "card closed" },
				["retry", "manual", "forfeit"],
				null,
			),
		).toMatch(/^Refund of €40\.00 failed \(card closed\)\. Their workshop/);
	});
});
