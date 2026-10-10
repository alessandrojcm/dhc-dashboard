import type {
	BeginnersWorkshopConsole,
	BeginnersWorkshopNextBatch,
} from "@dhc/api-client";
import { describe, expect, it } from "vitest";
import {
	consoleTimeline,
	failedRefundText,
	formatDublinInstant,
	formatRefundAmount,
	holdLabel,
	nextBatchHeadline,
	nextBatchSize,
	nowCard,
	refundLabel,
} from "#lib/beginners-workshops/console.js";

function next(
	overrides: Partial<BeginnersWorkshopNextBatch> = {},
): BeginnersWorkshopNextBatch {
	return {
		status: "scheduled",
		goesOutAt: "2026-10-28T10:00:00Z",
		number: 2,
		size: 2,
		capacity: 3,
		paid: 1,
		people: [
			{
				firstName: "Aoife",
				lastName: "Byrne",
				minor: false,
				queueDate: "2025-01-01T12:00:00Z",
			},
			{
				firstName: "Bea",
				lastName: "Kelly",
				minor: true,
				queueDate: "2025-02-01T12:00:00Z",
			},
		],
		...overrides,
	};
}

function view(
	overrides: Partial<BeginnersWorkshopConsole> = {},
): BeginnersWorkshopConsole {
	return {
		workshop: {
			id: "6d9e6110-fc8c-4dcf-b64f-db21b20d5140",
			status: "scheduled",
			venue: "St. Andrew's Hall",
			date: "2026-11-14",
			startTime: "18:30",
			capacity: 3,
			feeCents: 4000,
			paymentCutoff: "2026-11-11T18:30:00Z",
			paymentCutoffDate: "2026-11-11",
			paymentCutoffTime: "18:30",
			contactFromDate: "2026-10-20",
			contactFromEditable: false,
			paymentWindowDays: 7,
			stage: "window_open",
			seats: { capacity: 3, paid: 1, holds: 0, free: 2 },
			alerts: [],
			staff: { coach: null, assistants: [] },
		},
		batches: [
			{
				number: 1,
				size: 3,
				sentAt: "2026-10-20T09:00:00Z",
				windowEndsAt: "2026-10-27T23:59:59.999999Z",
			},
		],
		pause: {
			paused: false,
			pausedAt: null,
			pausedBy: null,
			resumedAt: null,
			resumedBy: null,
		},
		nextBatch: next(),
		roster: { seated: [], asked: [], out: [] },
		failedRefunds: [],
		attention: [],
		fastTrackOpen: true,
		...overrides,
	};
}

describe("formatDublinInstant", () => {
	it("shows the Dublin wall clock across the clock change", () => {
		expect(formatDublinInstant("2026-10-20T09:00:00Z")).toBe(
			"Tue 20 Oct, 10:00",
		);
		expect(formatDublinInstant("2026-10-28T10:00:00Z")).toBe(
			"Wed 28 Oct, 10:00",
		);
	});
});

describe("the Next Batch preview", () => {
	it("says when it goes out, or why not", () => {
		expect(nextBatchHeadline(next())).toBe(
			"Batch 2 goes out Wed 28 Oct, 10:00",
		);
		expect(nextBatchHeadline(next({ status: "due" }))).toMatch(/next sweep/);
		expect(nextBatchHeadline(next({ status: "due", people: [] }))).toBe(
			"Batch 2 is due, but nobody is waiting",
		);
		expect(nextBatchHeadline(next({ status: "paused" }))).toMatch(
			/^Batches are paused/,
		);
		expect(nextBatchHeadline(next({ status: "full" }))).toMatch(
			/as soon as a seat frees/,
		);
		expect(nextBatchHeadline(next({ status: "closed" }))).toMatch(
			/No more Batches/,
		);
	});

	it("explains its size as capacity − paid", () => {
		expect(nextBatchSize(next())).toBe("3 seats − 1 paid = 2");
		expect(nextBatchSize(next({ people: [] }))).toBe(
			"3 seats − 1 paid = 2; only 0 waiting",
		);
	});
});

describe("consoleTimeline", () => {
	it("marks the open window now and the next Batch next", () => {
		const steps = consoleTimeline(view());
		expect(steps.map((step) => [step.label, step.state])).toEqual([
			["Scheduled", "done"],
			["Batch 1 · 3 contacted", "now"],
			["Batch 2 · 2 proposed", "next"],
			["Payment Cutoff · pre-workshop info", "next"],
			["Workshop · check-in from an hour before", "next"],
			["Attendance Finalisation", "next"],
			["Follow-up email", "next"],
		]);
		expect(steps[1]?.when).toBe("Tue 20 Oct, 10:00 → Tue 27 Oct, 23:59");
	});

	it("has no next Batch once payment has closed, and marks the cutoff done", () => {
		const base = view();
		const steps = consoleTimeline(
			view({
				workshop: { ...base.workshop, stage: "payment_closed" },
				nextBatch: next({ status: "closed", people: [] }),
			}),
		);
		expect(steps.map((step) => step.label)).not.toContain(
			"Batch 2 · 0 proposed",
		);
		expect(
			steps.find((step) => step.label.startsWith("Payment Cutoff"))?.state,
		).toBe("done");
	});

	it("strikes through what a cancelled workshop will never do", () => {
		const base = view();
		const steps = consoleTimeline(
			view({
				workshop: { ...base.workshop, status: "cancelled", stage: "cancelled" },
			}),
		);
		expect(steps.at(-1)).toEqual({ label: "Cancelled", state: "done" });
		expect(
			steps.filter((step) => step.state === "skipped").map((s) => s.label),
		).toEqual([
			"Payment Cutoff · pre-workshop info",
			"Workshop · check-in from an hour before",
			"Attendance Finalisation",
			"Follow-up email",
		]);
	});
});

describe("nowCard", () => {
	it("pairs the stage with the Next Batch", () => {
		expect(nowCard(view())).toEqual({
			title: "Batch 1 window open — ends Tue 27 Oct, 23:59",
			body: "1 of 3 paid. Batch 2 goes out Wed 28 Oct, 10:00.",
		});
	});

	it("counts who is in once door check-in is open (ALE-390)", () => {
		const base = view();
		const seated = (id: string, checkedInAt: string | null) => ({
			id,
			state: "paid" as const,
			origin: "batch" as const,
			batchNumber: 1,
			firstName: "Cian",
			lastName: "Doyle",
			minor: false,
			queueDate: "2024-12-01T12:00:00Z",
			contactedAt: "2026-10-20T09:00:00Z",
			holdExpiresAt: null,
			checkedInAt,
			refund: null,
		});
		const today = (stage: "today_before_check_in" | "check_in_open") =>
			view({
				workshop: { ...base.workshop, stage },
				roster: {
					seated: [seated("a", "2026-11-14T18:00:00Z"), seated("b", null)],
					asked: [],
					out: [],
				},
			});

		expect(nowCard(today("today_before_check_in"))).toEqual({
			title: "Today — check-in opens an hour before",
			body: "1 of 3 paid. Door check-in opens an hour before the 18:30 start.",
		});
		expect(nowCard(today("check_in_open"))).toEqual({
			title: "Today — check-in open",
			body: "1 of 2 in. 1 of 3 paid.",
		});
	});
});

describe("nowCard after the Payment Cutoff (ALE-385)", () => {
	const intake = (holdExpiresAt: string | null) => ({
		id: crypto.randomUUID(),
		state: "contacted" as const,
		origin: "batch" as const,
		batchNumber: 1,
		queueDate: "2025-01-01T12:00:00Z",
		contactedAt: "2026-10-20T09:00:00Z",
		holdExpiresAt,
		checkedInAt: null,
		refund: null,
		firstName: "Aoife",
		lastName: "Byrne",
		minor: false,
	});

	it("says what the cutoff did", () => {
		const base = view();
		expect(
			nowCard(
				view({ workshop: { ...base.workshop, stage: "payment_closed" } }),
			),
		).toEqual({
			title: "Payment closed",
			body: "1 of 3 paid. Paid people get the pre-workshop info; unpaid people lapse, or go back to the queue if the workshop was full.",
		});
	});

	it("names who is still in checkout or not settled yet", () => {
		const base = view();
		const card = nowCard(
			view({
				workshop: { ...base.workshop, stage: "payment_closed" },
				roster: {
					seated: [],
					asked: [intake("2026-11-11T18:50:00Z"), intake(null)],
					out: [],
				},
			}),
		);
		expect(card.body).toMatch(
			/1 still in checkout — settled when Stripe ends the payment\. 1 settled at the next sweep\.$/,
		);
	});
});

describe("holdLabel (ALE-381)", () => {
	const now = new Date("2026-10-22T11:00:00Z");

	it("names when a live Seat Hold runs out on the Dublin clock", () => {
		expect(holdLabel({ holdExpiresAt: "2026-10-22T11:30:00Z" }, now)).toBe(
			"Paying now · hold until 12:30",
		);
	});

	it("keeps a hold Stripe has not ended yet as ending, and is null without one", () => {
		expect(holdLabel({ holdExpiresAt: "2026-10-22T10:59:00Z" }, now)).toBe(
			"Paying now · hold ending",
		);
		expect(holdLabel({ holdExpiresAt: null }, now)).toBeNull();
	});
});

describe("refundLabel (ALE-382)", () => {
	const refund = {
		status: "completed" as const,
		method: "stripe" as const,
		automatic: true,
		amountCents: 4000,
		currency: "eur",
	};

	it("names failed, automatic and manual refunds", () => {
		expect(refundLabel({ refund: { ...refund, status: "failed" } })).toEqual({
			text: "Refund failed",
			tone: "failed",
		});
		expect(refundLabel({ refund })?.text).toBe("Refunded automatically");
		expect(
			refundLabel({ refund: { ...refund, status: "pending" } })?.text,
		).toBe("Automatic refund in progress");
		expect(refundLabel({ refund: { ...refund, method: "manual" } })?.text).toBe(
			"Refunded manually",
		);
		expect(refundLabel({ refund: null })).toBeNull();
	});

	it("words a failed refund for Needs attention", () => {
		expect(formatRefundAmount(1250, "gbp")).toBe("12.50 GBP");
		expect(
			failedRefundText({
				id: "r",
				intakeId: "i",
				firstName: "Dara",
				lastName: null,
				amountCents: 3500,
				currency: "eur",
				reason: "paid_after_close",
				failedAt: null,
			}),
		).toBe(
			"Refund of €35.00 to Dara failed (they paid after their Intake closed). Retry it, or record a manual refund if you paid them back another way.",
		);
	});
});
