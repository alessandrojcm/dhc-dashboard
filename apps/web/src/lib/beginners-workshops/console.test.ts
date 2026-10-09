import type {
	BeginnersWorkshopConsole,
	BeginnersWorkshopNextBatch,
} from "@dhc/api-client";
import { describe, expect, it } from "vitest";
import {
	carriedFeeLabel,
	consoleTimeline,
	emailLogLine,
	failedRefundText,
	followUpLabel,
	formatDublinInstant,
	formatRefundAmount,
	historyLine,
	holdLabel,
	invitationSummary,
	INTAKE_COMMANDS,
	intakeCommandDone,
	intakeCommandLabel,
	nextBatchHeadline,
	nextBatchSize,
	nowCard,
	refundLabel,
	refundTimingHint,
	daysToGo,
	isIntakeButtonCommand,
	rosterGroups,
	unconfirmedCarriedFeeText,
	standingLabel,
	unpaidAfterWindowText,
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
				confirms: false,
			},
			{
				firstName: "Bea",
				lastName: "Kelly",
				minor: true,
				queueDate: "2025-02-01T12:00:00Z",
				confirms: false,
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
			seats: {
				capacity: 3,
				paid: 1,
				holds: 0,
				free: 2,
				attended: 0,
				noShow: 0,
			},
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
		roster: { seated: [], asked: [], attended: [], noShow: [], out: [] },
		failedRefunds: [],
		unpaidAfterWindow: [],
		unconfirmedCarriedFees: [],
		attention: [],
		fastTrackOpen: true,
		fastTrackHoldersOnly: false,
		finalisation: null,
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
			standing: "waiting" as const,
			medical: false,
			windowEndsAt: "2026-10-27T22:59:59.999999Z",
			linkGeneration: 1,
			emailLog: [],
			history: [],
			availableCommands: [],
			paidVia: null,
			carriedFee: null,
		});
		const today = (stage: "today_before_check_in" | "check_in_open") =>
			view({
				workshop: { ...base.workshop, stage },
				roster: {
					seated: [seated("a", "2026-11-14T18:00:00Z"), seated("b", null)],
					asked: [],
					attended: [],
					noShow: [],
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
		standing: "waiting" as const,
		medical: false,
		windowEndsAt: "2026-10-27T22:59:59.999999Z",
		linkGeneration: 1,
		emailLog: [],
		history: [],
		availableCommands: [],
		paidVia: null,
		carriedFee: null,
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
					attended: [],
					noShow: [],
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

describe("after Attendance Finalisation (ALE-391)", () => {
	const intake = (id: string, state: "attended" | "no_show") => ({
		id,
		state,
		origin: "batch" as const,
		batchNumber: 1,
		queueDate: "2025-01-01T12:00:00Z",
		contactedAt: "2026-10-20T09:00:00Z",
		holdExpiresAt: null,
		checkedInAt: state === "attended" ? "2026-11-14T18:10:00Z" : null,
		firstName: "Aoife",
		lastName: "Byrne",
		minor: false,
		refund: null,
		standing:
			state === "attended" ? ("attended" as const) : ("removed" as const),
		medical: false,
		windowEndsAt: "2026-10-27T22:59:59.999999Z",
		linkGeneration: 1,
		emailLog: [],
		history: [],
		availableCommands: [],
		paidVia: null,
		carriedFee: null,
	});

	function finalised(by: string | null = "Aoife Coach") {
		const base = view();
		return view({
			workshop: {
				...base.workshop,
				status: "finalised",
				stage: "finalised",
				seats: { ...base.workshop.seats, attended: 2, noShow: 1 },
			},
			nextBatch: next({ status: "closed", people: [] }),
			roster: {
				seated: [],
				asked: [],
				attended: [intake("a", "attended"), intake("b", "attended")],
				noShow: [intake("c", "no_show")],
				out: [],
			},
			finalisation: {
				at: "2026-11-14T20:05:00Z",
				by,
				followUpAt: "2026-11-15T10:00:00Z",
				invitations: { attended: 2, invited: 1, joined: 0 },
			},
		});
	}

	it("groups the roster as Attended / No-show / Out", () => {
		expect(
			rosterGroups(finalised()).map((group) => [
				group.title,
				group.intakes.length,
			]),
		).toEqual([
			["Attended", 2],
			["No-show", 1],
			["Out of this workshop", 0],
		]);
		expect(rosterGroups(view()).map((group) => group.title)).toEqual([
			"Seated (paid)",
			"Asked, not paid yet",
			"Out of this workshop",
		]);
	});

	it("says who finalised it and the outcome", () => {
		expect(nowCard(finalised())).toEqual({
			title: "Finalised Sat 14 Nov, 20:05 by Aoife Coach",
			body: "2 attended · 1 no-show. Attended people get the follow-up email at 10:00 the next morning. Only corrections and invites remain.",
		});
		expect(nowCard(finalised(null)).title).toBe(
			"Finalised Sat 14 Nov, 20:05 automatically at the end of the day",
		);
	});

	it("marks the follow-up done from 10:00 the next morning", () => {
		const step = (now: string) =>
			consoleTimeline(finalised(), new Date(now)).slice(-2);

		expect(step("2026-11-15T09:59:00Z")).toEqual([
			{
				label: "Attendance Finalisation",
				when: "Sat 14 Nov, 20:05 · Aoife Coach",
				state: "done",
			},
			{ label: "Follow-up email", when: "Sun 15 Nov, 10:00", state: "next" },
		]);
		expect(step("2026-11-15T10:00:00Z")[1]?.state).toBe("done");
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

describe("Invitation handoff (ALE-392)", () => {
	it("words the finalised console's handoff line", () => {
		expect(invitationSummary({ attended: 3, invited: 2, joined: 1 })).toBe(
			"3 attended · 2 invited · 1 joined",
		);
	});

	it("labels an attended person's standing, leaving the Invitable ones to the Invite button", () => {
		expect(standingLabel("attended")).toBeNull();
		expect(standingLabel("invited")).toBe("Invited");
		expect(standingLabel("joined")).toBe("Joined");
		expect(standingLabel(null)).toBeNull();
	});

	it("says whether the Follow-up went out or when it goes", () => {
		expect(
			followUpLabel({ status: "scheduled", at: "2026-11-15T10:00:00Z" }),
		).toBe("Scheduled Sun 15 Nov, 10:00");
		expect(followUpLabel({ status: "sent", at: "2026-11-15T10:00:01Z" })).toBe(
			"Sent Sun 15 Nov, 10:00",
		);
	});
});

describe("ALE-386: console Intake commands, email log and history", () => {
	it("names every command and words a repeat that changed nothing", () => {
		expect(INTAKE_COMMANDS).toEqual([
			"decline",
			"defer",
			"confirm",
			"cancel_with_refund",
			"withdraw",
			"resend_link",
			"rotate_link",
		]);
		expect(INTAKE_COMMANDS.map(intakeCommandLabel)).toEqual([
			"Decline",
			"Defer",
			"Confirm with Carried Fee",
			"Cancel with refund",
			"Withdraw…",
			"Resend link",
			"Rotate link",
		]);
		expect(intakeCommandDone("rotate_link", "done")).toBe(
			"Link rotated — the old one no longer works",
		);
		expect(intakeCommandDone("decline", "already_done")).toBe(
			"Already done — nothing changed",
		);
	});

	it("ALE-388: words Carried Fees, a person's own confirm and a holder who hasn't confirmed", () => {
		expect(carriedFeeLabel("held")).toBe("Carried Fee · held");
		expect(carriedFeeLabel(null)).toBeNull();
		expect(
			historyLine({
				command: "confirm",
				actor: null,
				occurredAt: "2026-10-22T11:00:00Z",
				note: null,
			}),
		).toBe("Confirmed with Carried Fee · by the person · Thu 22 Oct, 12:00");
		expect(
			historyLine({
				command: "defer",
				actor: null,
				occurredAt: "2026-10-22T11:00:00Z",
				note: null,
			}),
		).toBe("Deferred · a former member · Thu 22 Oct, 12:00");
		expect(
			unconfirmedCarriedFeeText({
				id: "0b0c3b2e-8a43-4a8d-9a39-5b9d8a2ab002",
				firstName: "Dara",
				lastName: "Nolan",
				batchNumber: 1,
				contactedAt: "2026-10-20T09:00:00Z",
			}),
		).toMatch(
			/^Dara Nolan holds a Carried Fee and hasn't confirmed \(contacted Tue 20 Oct, 10:00\)/,
		);
	});

	it("shows a queued email's time and a scheduled one's due time or the next sweep", () => {
		const now = new Date("2026-11-01T12:00:00Z");
		expect(
			emailLogLine(
				{ emailType: "declined", at: "2026-10-22T11:00:00Z", scheduled: false },
				now,
			),
		).toEqual({
			label: "Declined",
			when: "Thu 22 Oct, 12:00",
			scheduled: false,
		});
		expect(
			emailLogLine(
				{
					emailType: "pre_workshop",
					at: "2026-11-11T18:30:00Z",
					scheduled: true,
				},
				now,
			),
		).toEqual({
			label: "Pre-workshop info (scheduled)",
			when: "Wed 11 Nov, 18:30",
			scheduled: true,
		});
		expect(
			emailLogLine(
				{
					emailType: "pre_workshop",
					at: "2026-10-30T18:30:00Z",
					scheduled: true,
				},
				now,
			).when,
		).toBe("at the next sweep");
	});

	it("words a history entry, and an actor who is gone", () => {
		expect(
			historyLine({
				command: "decline",
				actor: null,
				occurredAt: "2026-10-22T11:00:00Z",
				note: null,
			}),
		).toBe("Declined · a former member · Thu 22 Oct, 12:00");
	});

	it("words someone unpaid after a fast-track window", () => {
		expect(
			unpaidAfterWindowText({
				id: "0b0c3b2e-8a43-4a8d-9a39-5b9d8a2ab002",
				firstName: null,
				lastName: null,
				batchNumber: null,
				windowEndsAt: "2026-11-11T18:30:00Z",
			}),
		).toMatch(
			/^Anonymised hasn't paid — their payment window ended Wed 11 Nov, 18:30\./,
		);
	});
});

describe("ALE-387: the refund-timing hint", () => {
	// 20:00 UTC on 6 Nov is 20:00 Dublin (GMT): Dublin today is 6 Nov.
	const now = new Date("2026-11-06T20:00:00Z");

	it("counts calendar days on the Dublin wall clock", () => {
		expect(daysToGo("2026-11-14", now)).toBe(8);
		expect(daysToGo("2026-11-13", now)).toBe(7);
		expect(daysToGo("2026-11-06", now)).toBe(0);
		// 23:30 UTC on 31 Oct is 23:30 Dublin (GMT after the clocks change).
		expect(daysToGo("2026-11-01", new Date("2026-10-31T23:30:00Z"))).toBe(1);
		// 23:30 UTC on 24 Oct is already 25 Oct in Dublin (IST).
		expect(daysToGo("2026-10-26", new Date("2026-10-24T23:30:00Z"))).toBe(1);
	});

	it("shows from 7 days out until the workshop's day, never before or after", () => {
		expect(refundTimingHint("2026-11-14", now)).toBeNull();
		expect(refundTimingHint("2026-11-13", now)).toBe(
			"Less than 7 days to go — there's no deadline; whether to refund is your call.",
		);
		expect(refundTimingHint("2026-11-07", now)).toMatch(
			/^The workshop is tomorrow/,
		);
		expect(refundTimingHint("2026-11-06", now)).toMatch(
			/^The workshop is today/,
		);
		expect(refundTimingHint("2026-11-05", now)).toBeNull();
	});

	it("withdraw opens its own dialog; every other command is a button", () => {
		expect(isIntakeButtonCommand("withdraw")).toBe(false);
		expect(isIntakeButtonCommand("cancel_with_refund")).toBe(true);
	});
});
