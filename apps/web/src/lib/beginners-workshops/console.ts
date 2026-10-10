/**
 * ALE-380: how the workshop console words Phoenix's console read model —
 * the lifecycle timeline, the "Now" card, the Next Batch preview and the
 * roster groups. Every judgement (stage, when the next Batch goes, who is in
 * it, its size) is Phoenix's; this module only names and orders it.
 * Instants are shown on the Europe/Dublin wall clock.
 */
import type {
	BeginnersWorkshopConsole,
	BeginnersWorkshopIntakeState,
	BeginnersWorkshopNextBatch,
	BeginnersWorkshopRosterIntake,
} from "@dhc/api-client";
import { stageLabel } from "#lib/beginners-workshops/presentation.js";

const dublinParts = new Intl.DateTimeFormat("en-IE", {
	timeZone: "Europe/Dublin",
	weekday: "short",
	day: "numeric",
	month: "short",
	hour: "2-digit",
	minute: "2-digit",
	hourCycle: "h23",
});

/** An instant on the Dublin wall clock: `Tue 20 Oct, 10:00`. */
export function formatDublinInstant(iso: string): string {
	const parts = Object.fromEntries(
		dublinParts
			.formatToParts(new Date(iso))
			.map((part) => [part.type, part.value]),
	);
	return `${parts.weekday} ${parts.day} ${parts.month}, ${parts.hour}:${parts.minute}`;
}

export type TimelineStep = {
	label: string;
	when?: string;
	state: "done" | "now" | "next" | "skipped";
};

const AFTER_CUTOFF = new Set([
	"payment_closed",
	"today_before_check_in",
	"check_in_open",
	"awaiting_finalisation",
	"finalised",
]);

/** The lifecycle timeline: each step done, now or next; struck through when cancelled. */
export function consoleTimeline(
	view: BeginnersWorkshopConsole,
): TimelineStep[] {
	const { workshop, batches, nextBatch } = view;
	const stage = workshop.stage;
	const cancelled = stage === "cancelled";
	const finalised = stage === "finalised";
	const pending = (now: boolean): TimelineStep["state"] =>
		cancelled ? "skipped" : now ? "now" : "next";

	const steps: TimelineStep[] = [{ label: "Scheduled", state: "done" }];

	batches.forEach((batch, index) => {
		const latest = index === batches.length - 1;
		steps.push({
			label: `Batch ${batch.number} · ${batch.size} contacted`,
			when: `${formatDublinInstant(batch.sentAt)} → ${formatDublinInstant(batch.windowEndsAt)}`,
			state: latest && stage === "window_open" ? "now" : "done",
		});
	});

	if (
		workshop.status === "scheduled" &&
		nextBatch.status !== "closed" &&
		nextBatch.status !== "full"
	) {
		steps.push({
			label: `Batch ${nextBatch.number} · ${nextBatch.people.length} proposed`,
			when: nextBatchWhen(nextBatch),
			state:
				stage === "next_batch_due" ||
				stage === "batches_paused" ||
				stage === "before_contact_from"
					? "now"
					: "next",
		});
	}

	steps.push({
		label: "Payment Cutoff · pre-workshop info",
		when: formatDublinInstant(workshop.paymentCutoff),
		state: cancelled
			? "skipped"
			: stage === "payment_closed"
				? "now"
				: AFTER_CUTOFF.has(stage)
					? "done"
					: "next",
	});
	steps.push({
		label: "Workshop · check-in from an hour before",
		when: `${workshop.date} ${workshop.startTime}`,
		state: finalised
			? "done"
			: pending(stage === "today_before_check_in" || stage === "check_in_open"),
	});
	steps.push({
		label: "Attendance Finalisation",
		when: "door “Finish”, or end of day",
		state: finalised ? "done" : pending(stage === "awaiting_finalisation"),
	});
	steps.push({
		label: "Follow-up email",
		when: "10:00 the next morning",
		state: pending(false),
	});
	if (cancelled) steps.push({ label: "Cancelled", state: "done" });
	return steps;
}

/** When the next Batch goes, in a few words (or why it does not). */
export function nextBatchWhen(next: BeginnersWorkshopNextBatch): string {
	switch (next.status) {
		case "due":
			return "goes out at the next sweep";
		case "scheduled":
			return next.goesOutAt
				? `goes out ${formatDublinInstant(next.goesOutAt)}`
				: "goes out at 10:00";
		case "paused":
			return "paused";
		case "full":
			return "when a seat frees";
		case "closed":
			return "no more Batches before the cutoff";
	}
}

/** The Next Batch preview's headline. */
export function nextBatchHeadline(next: BeginnersWorkshopNextBatch): string {
	const batch = `Batch ${next.number}`;
	switch (next.status) {
		case "due":
			return next.people.length
				? `${batch} goes out at the next sweep, within a few minutes`
				: `${batch} is due, but nobody is waiting`;
		case "scheduled":
			return `${batch} ${nextBatchWhen(next)}`;
		case "paused":
			return `Batches are paused — ${batch} goes out at the next sweep after you resume`;
		case "full":
			return `Every seat is paid — ${batch} goes out as soon as a seat frees`;
		case "closed":
			return "No more Batches — payment closes at the Payment Cutoff";
	}
}

/** Why the Batch is the size it is: capacity − paid, and how many are waiting. */
export function nextBatchSize(next: BeginnersWorkshopNextBatch): string {
	const sum = `${next.capacity} seats − ${next.paid} paid = ${next.size}`;
	if (next.people.length >= next.size) return sum;
	return `${sum}; only ${next.people.length} waiting`;
}

/** The console's "Now" card. */
export type NowCard = { title: string; body: string };

/** The "Now" card for the workshop's stage. */
export function nowCard(view: BeginnersWorkshopConsole): NowCard {
	const { workshop, batches, nextBatch } = view;
	const latest = batches.at(-1);
	const seats = `${workshop.seats.paid} of ${workshop.capacity} paid`;
	switch (workshop.stage) {
		case "window_open":
			return {
				title: `Batch ${latest?.number ?? 1} window open${latest ? ` — ends ${formatDublinInstant(latest.windowEndsAt)}` : ""}`,
				body: `${seats}. ${nextBatchHeadline(nextBatch)}.`,
			};
		case "before_contact_from":
		case "next_batch_due":
		case "batches_paused":
		case "full":
			return {
				title: stageLabel(workshop.stage),
				body: `${seats}. ${nextBatchHeadline(nextBatch)}.`,
			};
		default:
			return { title: stageLabel(workshop.stage), body: seats };
	}
}

/** The roster groups before Attendance Finalisation, in display order. */
export function rosterGroups(view: BeginnersWorkshopConsole): {
	key: "seated" | "asked" | "out";
	title: string;
	intakes: BeginnersWorkshopRosterIntake[];
}[] {
	return [
		{ key: "seated", title: "Seated (paid)", intakes: view.roster.seated },
		{
			key: "asked",
			title: "Asked, not paid yet",
			intakes: view.roster.asked,
		},
		{ key: "out", title: "Out of this workshop", intakes: view.roster.out },
	];
}

const INTAKE_STATE_LABELS = {
	contacted: "Contacted",
	paid: "Paid",
	attended: "Attended",
	no_show: "No-show",
	lapsed: "Lapsed",
	declined: "Declined",
	returned: "Back in the queue",
	deferred: "Deferred",
	cancelled_refunded: "Refunded",
	withdrawn: "Withdrawn",
} satisfies Record<BeginnersWorkshopIntakeState, string>;

export function intakeStateLabel(state: BeginnersWorkshopIntakeState): string {
	return INTAKE_STATE_LABELS[state];
}

/** `Batch 2` or `Fast-track`. */
export function intakeOrigin(intake: BeginnersWorkshopRosterIntake): string {
	return intake.origin === "batch" && intake.batchNumber
		? `Batch ${intake.batchNumber}`
		: "Fast-track";
}

/** A person's name, or that they were anonymised. */
export function personName(person: {
	firstName: string | null;
	lastName: string | null;
}): string {
	const name = [person.firstName, person.lastName].filter(Boolean).join(" ");
	return name || "Anonymised";
}
