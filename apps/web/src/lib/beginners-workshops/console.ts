/**
 * ALE-380: how the workshop console words Phoenix's console read model —
 * the lifecycle timeline, the "Now" card, the Next Batch preview and the
 * roster groups. Every judgement (stage, when the next Batch goes, who is in
 * it, its size) is Phoenix's; this module only names and orders it.
 * Instants are shown on the Europe/Dublin wall clock.
 */
import type {
	BeginnersCarriedFeeStatus,
	BeginnersWorkshopAttendanceCorrection,
	BeginnersWorkshopConsole,
	BeginnersWorkshopConsoleInvitations,
	BeginnersWorkshopFollowUp,
	BeginnersWorkshopFailedRefund,
	BeginnersWorkshopIntakeCommand,
	BeginnersWorkshopIntakeEmailLogEntry,
	BeginnersWorkshopIntakeHistoryEntry,
	BeginnersWorkshopIntakeRefund,
	BeginnersWorkshopIntakeState,
	BeginnersWorkshopNextBatch,
	BeginnersWorkshopRosterIntake,
	BeginnersWorkshopUnconfirmedCarriedFee,
	WaitlistStatus,
	BeginnersWorkshopUnpaidAfterWindow,
} from "@dhc/api-client";
import { INTAKE_EMAIL_TYPES } from "#lib/beginners-workshops/intake-emails/presentation.js";
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
	now: Date = new Date(),
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
		// ALE-385: the cutoff pass runs at the first sweep after the cutoff.
		state: cancelled ? "skipped" : AFTER_CUTOFF.has(stage) ? "done" : "next",
	});
	steps.push({
		label: "Workshop · check-in from an hour before",
		when: `${workshop.date} ${workshop.startTime}`,
		state: finalised
			? "done"
			: pending(stage === "today_before_check_in" || stage === "check_in_open"),
	});
	const finalisation = view.finalisation;
	steps.push({
		label: "Attendance Finalisation",
		when: finalisation
			? `${formatDublinInstant(finalisation.at)} · ${finalisation.by ?? "automatically"}`
			: "door “Finish”, or end of day",
		state: finalised ? "done" : pending(stage === "awaiting_finalisation"),
	});
	// ALE-391: the follow-up pass runs at the first sweep after its time.
	const followUpDone =
		!!finalisation &&
		new Date(finalisation.followUpAt).getTime() <= now.getTime();
	steps.push({
		label: "Follow-up email",
		when: finalisation
			? formatDublinInstant(finalisation.followUpAt)
			: "10:00 the next morning",
		state: followUpDone ? "done" : finalised ? "next" : pending(false),
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
		case "payment_closed":
			return {
				title: stageLabel(workshop.stage),
				body: paymentClosedBody(view, seats),
			};
		case "today_before_check_in":
			return {
				title: stageLabel(workshop.stage),
				body: `${seats}. Door check-in opens an hour before the ${workshop.startTime} start.`,
			};
		case "check_in_open": {
			const checkedIn = view.roster.seated.filter(
				(intake) => intake.checkedInAt,
			).length;
			return {
				title: stageLabel(workshop.stage),
				body: `${checkedIn} of ${view.roster.seated.length} in. ${seats}.`,
			};
		}
		case "awaiting_finalisation":
			return {
				title: stageLabel(workshop.stage),
				body: `${seats}. Attendance finalises automatically within a few minutes of the end of the workshop day.`,
			};
		case "finalised":
			return {
				title: view.finalisation
					? `Finalised ${formatDublinInstant(view.finalisation.at)} ${
							view.finalisation.by
								? `by ${view.finalisation.by}`
								: "automatically at the end of the day"
						}`
					: stageLabel(workshop.stage),
				body: `${workshop.seats.attended} attended · ${workshop.seats.noShow} no-show. Attended people get the follow-up email at 10:00 the next morning. Only corrections and invites remain.`,
			};
		default:
			return { title: stageLabel(workshop.stage), body: seats };
	}
}

/**
 * ALE-385: what the Payment Cutoff did. Paid people got the pre-workshop
 * info; unpaid people lapsed or went back to the queue. Someone still in
 * checkout at the cutoff stays "asked" until Stripe ends their hold.
 */
function paymentClosedBody(
	view: BeginnersWorkshopConsole,
	seats: string,
): string {
	const inCheckout = view.roster.asked.filter((intake) => intake.holdExpiresAt);
	const waiting = view.roster.asked.length - inCheckout.length;
	const parts = [
		`${seats}. Paid people get the pre-workshop info; unpaid people lapse, or go back to the queue if the workshop was full`,
	];
	if (inCheckout.length)
		parts.push(
			`${inCheckout.length} still in checkout — settled when Stripe ends the payment`,
		);
	if (waiting) parts.push(`${waiting} settled at the next sweep`);
	return `${parts.join(". ")}.`;
}

/**
 * The roster groups, in display order: Seated (paid) / Asked, not paid yet /
 * Out before Attendance Finalisation, and Attended / No-show / Out after it.
 */
export function rosterGroups(view: BeginnersWorkshopConsole): {
	key: "seated" | "asked" | "attended" | "noShow" | "out";
	title: string;
	intakes: BeginnersWorkshopRosterIntake[];
}[] {
	if (view.workshop.status === "finalised") {
		return [
			{ key: "attended", title: "Attended", intakes: view.roster.attended },
			{ key: "noShow", title: "No-show", intakes: view.roster.noShow },
			{ key: "out", title: "Out of this workshop", intakes: view.roster.out },
		];
	}
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

const dublinTime = new Intl.DateTimeFormat("en-IE", {
	timeZone: "Europe/Dublin",
	hour: "2-digit",
	minute: "2-digit",
	hourCycle: "h23",
});

/**
 * ALE-381: a live Seat Hold on a roster row — `Paying now · hold until 12:30`
 * (Dublin) — or `null` without one. The seat stays taken until Stripe ends
 * the session, so a hold past its time still shows, as "ending".
 */
export function holdLabel(
	intake: Pick<BeginnersWorkshopRosterIntake, "holdExpiresAt">,
	now: Date = new Date(),
): string | null {
	if (!intake.holdExpiresAt) return null;
	const until = new Date(intake.holdExpiresAt);
	return until.getTime() > now.getTime()
		? `Paying now · hold until ${dublinTime.format(until)}`
		: "Paying now · hold ending";
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

/**
 * ALE-382: an Intake's refund status on its roster row — failed, automatic
 * or manual — or `null` without a refund.
 */
export function refundLabel(intake: {
	refund: BeginnersWorkshopIntakeRefund | null;
}): { text: string; tone: "failed" | "progress" | "done" } | null {
	const refund = intake.refund;
	if (!refund) return null;
	if (refund.status === "failed")
		return { text: "Refund failed", tone: "failed" };
	if (refund.method === "manual")
		return { text: "Refunded manually", tone: "done" };
	const kind = refund.automatic ? "Automatic refund" : "Refund";
	if (refund.status === "completed")
		return {
			text: refund.automatic ? "Refunded automatically" : "Refunded",
			tone: "done",
		};
	return { text: `${kind} in progress`, tone: "progress" };
}

const REFUND_REASONS = new Map([
	["policy_failed", "the payment didn't match the fee"],
	["paid_after_close", "they paid after their Intake closed"],
	["cancelled_with_refund", "cancelled with a refund"],
	["withdrawn", "withdrawn with a refund"],
]);

/** A refund amount: `€40.00`, or `12.50 GBP` outside euro. */
export function formatRefundAmount(cents: number, currency: string): string {
	const amount = (cents / 100).toFixed(2);
	return currency === "eur"
		? `€${amount}`
		: `${amount} ${currency.toUpperCase()}`;
}

/** The Needs attention line of a failed refund. */
export function failedRefundText(
	refund: BeginnersWorkshopFailedRefund,
): string {
	const reason = REFUND_REASONS.get(refund.reason);
	return `Refund of ${formatRefundAmount(refund.amountCents, refund.currency)} to ${personName(refund)} failed${reason ? ` (${reason})` : ""}. Retry it, or record a manual refund if you paid them back another way.`;
}

/** ALE-392: a finalised workshop's handoff line — `3 attended · 2 invited · 1 joined`. */
export function invitationSummary({
	attended,
	invited,
	joined,
}: BeginnersWorkshopConsoleInvitations): string {
	return `${attended} attended · ${invited} invited · ${joined} joined`;
}

/**
 * ALE-392: what an attended person's standing says about their Invitation.
 * `attended` is still Invitable (the row offers Invite instead of a label);
 * anything else is shown as is.
 */
export function standingLabel(standing: WaitlistStatus | null): string | null {
	switch (standing) {
		case "invited":
			return "Invited";
		case "joined":
			return "Joined";
		case "removed":
			return "Removed";
		case "waiting":
			return "Waiting";
		default:
			return null;
	}
}

/** ALE-392: the Invitable view's Follow-up column — `Sent Sun 25 Oct, 10:00` or `Scheduled …`. */
export function followUpLabel({
	status,
	at,
}: BeginnersWorkshopFollowUp): string {
	return `${status === "sent" ? "Sent" : "Scheduled"} ${formatDublinInstant(at)}`;
}

/**
 * ALE-386: how the console names Phoenix's Intake commands. Which commands an
 * Intake offers is Phoenix's `availableCommands`; this only words them. The
 * table is exhaustive over the generated enum, so a new command is a type
 * error until its copy is decided.
 */
const INTAKE_COMMAND_COPY = {
	decline: {
		label: "Decline",
		done: "Declined — they keep their place in the queue",
		history: "Declined",
	},
	defer: {
		label: "Defer",
		done: "Deferred — their fee is a Carried Fee and they keep their place in the queue",
		history: "Deferred",
	},
	confirm: {
		label: "Confirm with Carried Fee",
		done: "Place confirmed with their Carried Fee",
		history: "Confirmed with Carried Fee",
	},
	cancel_with_refund: {
		label: "Cancel with refund",
		done: "Cancelled — refund requested; they keep their place in the queue",
		history: "Cancelled with refund",
	},
	withdraw: {
		label: "Withdraw…",
		done: "Withdrawn from the Waitlist",
		history: "Withdrawn",
	},
	resend_link: {
		label: "Resend link",
		done: "Link resent",
		history: "Link resent",
	},
	rotate_link: {
		label: "Rotate link",
		done: "Link rotated — the old one no longer works",
		history: "Link rotated",
	},
	correct_attendance: {
		label: "Correct attendance",
		done: "Attendance corrected",
		history: "Attendance corrected",
	},
} satisfies Record<
	BeginnersWorkshopIntakeCommand,
	{ label: string; done: string; history: string }
>;

/** Every Intake command, in display order (Phoenix lists them in this order too). */
export const INTAKE_COMMANDS = [
	"decline",
	"defer",
	"confirm",
	"cancel_with_refund",
	"withdraw",
	"resend_link",
	"rotate_link",
	"correct_attendance",
] as const satisfies readonly BeginnersWorkshopIntakeCommand[];

/**
 * ALE-393: how the console words each attendance correction. Which ones an
 * Intake offers is Phoenix's `attendanceCorrections`; exhaustive over the
 * generated enum.
 */
const ATTENDANCE_CORRECTION_COPY = {
	attended: {
		label: "Mark attended",
		done: "Corrected to attended",
		history: "Attendance corrected to attended",
	},
	no_show: {
		label: "Mark no-show",
		done: "Corrected to no-show — they are removed from the Waitlist",
		history: "Attendance corrected to no-show",
	},
	deferred: {
		label: "Defer instead",
		done: "Deferred — their fee is a Carried Fee and they keep their place in the queue",
		history: "No-show corrected to deferred",
	},
} satisfies Record<
	BeginnersWorkshopAttendanceCorrection,
	{ label: string; done: string; history: string }
>;

/** Every attendance correction, in display order (Phoenix lists them in this order too). */
export const ATTENDANCE_CORRECTIONS = [
	"attended",
	"no_show",
	"deferred",
] as const satisfies readonly BeginnersWorkshopAttendanceCorrection[];

/** The button label of an attendance correction. */
export function attendanceCorrectionLabel(
	to: BeginnersWorkshopAttendanceCorrection,
): string {
	return ATTENDANCE_CORRECTION_COPY[to].label;
}

/** The toast after an attendance correction; a repeat that changed nothing says so. */
export function attendanceCorrectionDone(
	to: BeginnersWorkshopAttendanceCorrection,
	outcome: "done" | "already_done",
): string {
	return outcome === "already_done"
		? "Already done — nothing changed"
		: ATTENDANCE_CORRECTION_COPY[to].done;
}

/**
 * ALE-387: the commands that run straight from the Intake detail's command
 * buttons. `withdraw` needs the refund-or-forfeit choice, so it opens its
 * own dialog instead; (ALE-393) `correct_attendance` has a button per
 * correction in its own form.
 */
export const INTAKE_BUTTON_COMMANDS = [
	"decline",
	"defer",
	"confirm",
	"cancel_with_refund",
	"resend_link",
	"rotate_link",
] as const satisfies readonly BeginnersWorkshopIntakeCommand[];

export type IntakeButtonCommand = (typeof INTAKE_BUTTON_COMMANDS)[number];

/** Whether `command` runs from a command button (not its own dialog). */
export function isIntakeButtonCommand(
	command: BeginnersWorkshopIntakeCommand,
): command is IntakeButtonCommand {
	return INTAKE_BUTTON_COMMANDS.some((button) => button === command);
}

/** ALE-387: the refund-timing hint shows this many days before the workshop, or fewer. */
export const REFUND_HINT_DAYS = 7;

const dublinDate = new Intl.DateTimeFormat("en-CA", {
	timeZone: "Europe/Dublin",
	year: "numeric",
	month: "2-digit",
	day: "2-digit",
});

/** Whole calendar days from Dublin today to the workshop's civil `date`. */
export function daysToGo(date: string, now: Date = new Date()): number {
	const today = Date.parse(`${dublinDate.format(now)}T00:00:00Z`);
	return Math.round((Date.parse(`${date}T00:00:00Z`) - today) / 86_400_000);
}

/**
 * ALE-387 (story 77): the "less than N days to go" hint shown when choosing
 * between keeping the fee (defer) and refunding — from
 * `REFUND_HINT_DAYS` days before the workshop until its day, `null`
 * otherwise. There is no deadline: the club's policy is informal, so this
 * only reminds the coordinator how close the workshop is.
 */
export function refundTimingHint(
	date: string,
	now: Date = new Date(),
): string | null {
	const days = daysToGo(date, now);
	if (days < 0 || days > REFUND_HINT_DAYS) return null;
	const when =
		days === 0
			? "The workshop is today"
			: days === 1
				? "The workshop is tomorrow"
				: `Less than ${days} days to go`;
	return `${when} — there's no deadline; whether to refund is your call.`;
}

/** The button label of an Intake command. */
export function intakeCommandLabel(
	command: BeginnersWorkshopIntakeCommand,
): string {
	return INTAKE_COMMAND_COPY[command].label;
}

/** The toast after an Intake command; a repeat that changed nothing says so. */
export function intakeCommandDone(
	command: BeginnersWorkshopIntakeCommand,
	outcome: "done" | "already_done",
): string {
	return outcome === "already_done"
		? "Already done — nothing changed"
		: INTAKE_COMMAND_COPY[command].done;
}

/** One history line: `Declined · Clare Coord · Thu 22 Oct, 13:00`. */
export function historyLine(
	entry: BeginnersWorkshopIntakeHistoryEntry,
): string {
	// A confirm without an actor is the person's own, from their Intake page.
	const actor =
		entry.actor ??
		(entry.command === "confirm" ? "by the person" : "a former member");
	return [
		entry.correction
			? ATTENDANCE_CORRECTION_COPY[entry.correction].history
			: INTAKE_COMMAND_COPY[entry.command].history,
		actor,
		formatDublinInstant(entry.occurredAt),
	].join(" · ");
}

const CARRIED_FEE_LABELS = {
	held: "Carried Fee · held",
	applied: "Carried Fee · applied",
	spent: "Carried Fee · spent",
	refunded: "Carried Fee · refunded",
	forfeited: "Carried Fee · forfeited",
} satisfies Record<BeginnersCarriedFeeStatus, string>;

/**
 * ALE-388: a Carried Fee's status as the console and the Waitlist show it,
 * or `null` without one.
 */
export function carriedFeeLabel(
	status: BeginnersCarriedFeeStatus | null | undefined,
): string | null {
	return status ? CARRIED_FEE_LABELS[status] : null;
}

/** The Needs attention line of a Carried Fee holder who hasn't confirmed. */
export function unconfirmedCarriedFeeText(
	person: BeginnersWorkshopUnconfirmedCarriedFee,
): string {
	return `${personName(person)} holds a Carried Fee and hasn't confirmed (contacted ${formatDublinInstant(person.contactedAt)}). They can confirm until the workshop is finished; confirm for them if they replied by email.`;
}

/** One line of an Intake's email log, as the console shows it. */
export type EmailLogLine = { label: string; when: string; scheduled: boolean };

/**
 * One Intake Email log line. A queued email shows when it was queued; a
 * scheduled one shows when it is due, or that it goes at the next sweep.
 */
export function emailLogLine(
	entry: BeginnersWorkshopIntakeEmailLogEntry,
	now: Date = new Date(),
): EmailLogLine {
	const label = INTAKE_EMAIL_TYPES[entry.emailType].label;
	if (!entry.scheduled)
		return { label, when: formatDublinInstant(entry.at), scheduled: false };
	const due = new Date(entry.at).getTime() <= now.getTime();
	return {
		label: `${label} (scheduled)`,
		when: due ? "at the next sweep" : formatDublinInstant(entry.at),
		scheduled: true,
	};
}

/** The Needs attention line of someone still unpaid after their window. */
export function unpaidAfterWindowText(
	person: BeginnersWorkshopUnpaidAfterWindow,
): string {
	const window = person.batchNumber
		? `Batch ${person.batchNumber} window`
		: "payment window";
	return `${personName(person)} hasn't paid — their ${window} ended ${formatDublinInstant(person.windowEndsAt)}. They can still pay until the cutoff; resend their link or decline if they've said no.`;
}
