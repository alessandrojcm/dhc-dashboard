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
	BeginnersWorkshopIntakeCommand,
	BeginnersWorkshopIntakeEmailLogEntry,
	BeginnersWorkshopIntakeHistoryCommand,
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
import { formatDublinInstant, formatDublinTime } from "#lib/club-calendar.js";

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
			label: `Offer round ${batch.number} · ${batch.size} people emailed`,
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
			label: `Offer round ${nextBatch.number} · ${nextBatch.people.length} people next`,
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
		label: "Payment deadline · workshop information emailed",
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
		label: "Confirm attendance",
		when: finalisation
			? `${formatDublinInstant(finalisation.at)} · ${finalisation.by ?? "automatically"}`
			: "Use Finish workshop on the check-in page, or wait until the day ends",
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
			return "will be emailed within a few minutes";
		case "scheduled":
			return next.goesOutAt
				? `goes out ${formatDublinInstant(next.goesOutAt)}`
				: "goes out at 10:00";
		case "paused":
			return "paused";
		case "full":
			return "when a place frees up";
		case "closed":
			return "no more offers before the payment deadline";
	}
}

/** The Next Batch preview's headline. */
export function nextBatchHeadline(next: BeginnersWorkshopNextBatch): string {
	const batch = `Offer round ${next.number}`;
	switch (next.status) {
		case "due":
			return next.people.length
				? `${batch} will be emailed within a few minutes`
				: `${batch} is due, but nobody is waiting`;
		case "scheduled":
			return `${batch} ${nextBatchWhen(next)}`;
		case "paused":
			return `Automatic offers are paused. Resume to allow ${batch.toLowerCase()} when the next round is due`;
		case "full":
			return `All places are taken. ${batch} will be emailed when a place becomes available`;
		case "closed":
			return "No more automatic offers. New payments close at the payment deadline";
	}
}

/** Why the Batch is the size it is: capacity − paid, and how many are waiting. */
export function nextBatchSize(next: BeginnersWorkshopNextBatch): string {
	const sum = `${next.size} people to contact (${next.capacity} places, ${next.paid} already paid)`;
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
				title: `Offer round ${latest?.number ?? 1}: waiting for replies${latest ? ` until ${formatDublinInstant(latest.windowEndsAt)}` : ""}`,
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
				body: `${seats}. Attendance is confirmed automatically within a few minutes after the workshop day ends.`,
			};
		case "finalised":
			return {
				title: view.finalisation
					? `Attendance confirmed ${formatDublinInstant(view.finalisation.at)} ${
							view.finalisation.by
								? `by ${view.finalisation.by}`
								: "automatically at the end of the day"
						}`
					: stageLabel(workshop.stage),
				body: `${workshop.seats.attended} attended · ${workshop.seats.noShow} did not attend. Attendees get a follow-up email at 10:00 the next morning. You can correct attendance or send membership invitations.`,
			};
		case "cancelled":
			return {
				title: view.cancellation
					? `Cancelled ${formatDublinInstant(view.cancellation.at)}${
							view.cancellation.by ? ` by ${view.cancellation.by}` : ""
						}`
					: stageLabel(workshop.stage),
				body: cancelledBody(view),
			};
		default:
			return { title: stageLabel(workshop.stage), body: seats };
	}
}

/**
 * ALE-395: what the cancellation left behind. Paid people were deferred
 * (their fee is a Carried Fee, refundable through Refund Carried Fee);
 * everyone else went back to the Waitlist with their original priority.
 */
export function cancelledBody(view: BeginnersWorkshopConsole): string {
	const out = view.roster.out;
	const deferred = out.filter((intake) => intake.state === "deferred").length;
	const returned = out.filter((intake) => intake.state === "returned").length;
	return [
		`${plural(deferred, "paid person", "paid people")} given workshop credit · ${returned} back on the waitlist.`,
		"This workshop is cancelled. Use Refund credit to return a payment, or add the person to another workshop so they can confirm their place using their credit.",
	].join(" ");
}

function plural(count: number, one: string, many: string): string {
	return `${count} ${count === 1 ? one : many}`;
}

/** ALE-395: the Cancel dialog's lines, from Phoenix's `cancelPreview`. */
export function cancelPreviewLines(preview: {
	deferred: number;
	returned: number;
	released: number;
}): string[] {
	const lines = [
		`${plural(preview.deferred, "paid person", "paid people")} will receive credit for a later workshop and a cancellation email. You can refund the credit if they prefer.`,
		`${plural(preview.returned, "person offered a place", "people offered a place")} will return to the waitlist with their original priority and receive a cancellation email.`,
	];
	if (preview.released)
		lines.push(
			`${plural(preview.released, "place reserved during checkout", "places reserved during checkout")} will be released. Any payment that completes afterwards is refunded automatically.`,
		);
	lines.push("The assigned coach and assistants will be notified.");
	return lines;
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
	const awaitingCredit = view.roster.asked.filter(
		(intake) => !intake.holdExpiresAt && intake.carriedFee === "held",
	);
	const waiting =
		view.roster.asked.length - inCheckout.length - awaitingCredit.length;
	const parts = [
		`${seats}. People who paid receive the workshop information. Unpaid people without workshop credit are removed from the waitlist, or returned to it if the workshop was full`,
	];
	if (inCheckout.length)
		parts.push(
			`${inCheckout.length} still completing payment. Their places stay reserved until checkout ends`,
		);
	if (waiting)
		parts.push(`${waiting} awaiting an automatic update within a few minutes`);
	if (awaitingCredit.length)
		parts.push(
			`${awaitingCredit.length} with workshop credit can still confirm their place`,
		);
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
			{ key: "noShow", title: "Did not attend", intakes: view.roster.noShow },
			{ key: "out", title: "No longer attending", intakes: view.roster.out },
		];
	}
	return [
		{ key: "seated", title: "Confirmed places", intakes: view.roster.seated },
		{
			key: "asked",
			title: "Offered a place, awaiting payment or confirmation",
			intakes: view.roster.asked,
		},
		{ key: "out", title: "No longer attending", intakes: view.roster.out },
	];
}

const INTAKE_STATE_LABELS = {
	contacted: "Place offered",
	paid: "Paid",
	attended: "Attended",
	no_show: "Did not attend",
	lapsed: "Payment deadline missed",
	declined: "Declined",
	returned: "Back in the queue",
	deferred: "Moved to a later workshop",
	cancelled_refunded: "Cancelled; refund requested",
	withdrawn: "Withdrawn",
} satisfies Record<BeginnersWorkshopIntakeState, string>;

export function intakeStateLabel(state: BeginnersWorkshopIntakeState): string {
	return INTAKE_STATE_LABELS[state];
}

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
	return new Date(intake.holdExpiresAt).getTime() > now.getTime()
		? `Paying now · place reserved until ${formatDublinTime(intake.holdExpiresAt)}`
		: "Paying now · checkout ending";
}

/** `Batch 2` or `Fast-track`. */
export function intakeOrigin(intake: BeginnersWorkshopRosterIntake): string {
	return intake.origin === "batch" && intake.batchNumber
		? `Offer round ${intake.batchNumber}`
		: "Added by staff";
}

/** A person's name, or that they were anonymised. */
export function personName(person: {
	firstName: string | null;
	lastName: string | null;
}): string {
	const name = [person.firstName, person.lastName].filter(Boolean).join(" ");
	return name || "Personal details removed";
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
			return "Membership invitation sent";
		case "joined":
			return "Joined the club";
		case "removed":
			return "Removed from the waitlist";
		case "waiting":
			return "On the waitlist";
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
		label: "Decline place",
		done: "Declined — they keep their place in the queue",
		history: "Declined",
	},
	defer: {
		label: "Move to a later workshop",
		done: "Fee saved as workshop credit. They keep their place on the waitlist",
		history: "Moved to a later workshop",
	},
	confirm: {
		label: "Confirm using credit",
		done: "Place confirmed using workshop credit",
		history: "Place confirmed using workshop credit",
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
	refund_carried_fee: {
		label: "Refund credit",
		done: "Credit refund requested. They will need to pay for their next workshop",
		history: "Workshop credit refund requested",
	},
	resend_link: {
		label: "Resend link",
		done: "Link resent",
		history: "Link resent",
	},
	rotate_link: {
		label: "Replace link",
		done: "New link emailed. The old link no longer works",
		history: "Link replaced",
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
	"refund_carried_fee",
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
		label: "Mark as did not attend",
		done: "Marked as did not attend. They are removed from the waitlist",
		history: "Attendance corrected to did not attend",
	},
	deferred: {
		label: "Move to a later workshop instead",
		done: "Fee saved as workshop credit. They keep their place on the waitlist",
		history: "Non-attendance changed to a later workshop",
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
 * buttons. `withdraw` and (ALE-421) `refund_carried_fee` are the refund
 * module's, with their own dialogs; (ALE-393) `correct_attendance` has a
 * button per correction in its own form.
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

/**
 * ALE-395: a history row is a console command, the workshop's cancellation
 * or (story 97) a door check-in or its undo.
 */
const OTHER_HISTORY_LABELS = {
	cancel_workshop: "Workshop cancelled",
	check_in: "Checked in at the door",
	undo_check_in: "Check-in undone",
} satisfies Record<
	Exclude<
		BeginnersWorkshopIntakeHistoryCommand,
		BeginnersWorkshopIntakeCommand
	>,
	string
>;

function isOtherHistoryCommand(
	command: BeginnersWorkshopIntakeHistoryCommand,
): command is keyof typeof OTHER_HISTORY_LABELS {
	return Object.hasOwn(OTHER_HISTORY_LABELS, command);
}

function historyLabel(command: BeginnersWorkshopIntakeHistoryCommand): string {
	return isOtherHistoryCommand(command)
		? OTHER_HISTORY_LABELS[command]
		: INTAKE_COMMAND_COPY[command].history;
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
			: historyLabel(entry.command),
		actor,
		formatDublinInstant(entry.occurredAt),
	].join(" · ");
}

const CARRIED_FEE_LABELS = {
	held: "Workshop credit available",
	applied: "Workshop credit used for this place",
	spent: "Workshop credit used",
	refunded: "Workshop credit removed; refund requested",
	forfeited: "Workshop credit removed; payment kept",
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
	return `${personName(person)} has workshop credit but has not confirmed their place (offered ${formatDublinInstant(person.contactedAt)}). They can confirm until the workshop is finished. Confirm for them if they replied by email.`;
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
		when: due ? "within a few minutes" : formatDublinInstant(entry.at),
		scheduled: true,
	};
}

/** The Needs attention line of someone still unpaid after their window. */
export function unpaidAfterWindowText(
	person: BeginnersWorkshopUnpaidAfterWindow,
): string {
	const window = person.batchNumber
		? `offer round ${person.batchNumber} reply period`
		: "reply period";
	return `${personName(person)} has not paid. Their ${window} ended ${formatDublinInstant(person.windowEndsAt)}. They can still pay until the payment deadline. Resend their link or decline the place if they have said no.`;
}
