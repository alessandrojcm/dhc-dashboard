/**
 * The Beginners' Workshop scheduling and settings forms (ALE-378), used for
 * both `form(...)` and `.preflight(...)`. Each output is the Phoenix request
 * the remote form sends unchanged. Phoenix applies every default (the cutoff
 * 3 days before, contact from today, a 7-day window) and every cross-field
 * rule; these schemas only check what one field can know on its own.
 */
import type {
	BeginnersWorkshopCancelRequest,
	BeginnersWorkshopCorrectAttendanceRequest,
	BeginnersWorkshopFastTrackRequest,
	BeginnersWorkshopIntakeCommandRequest,
	BeginnersWorkshopManualRefundRequest,
	BeginnersWorkshopRescheduleRequest,
	BeginnersWorkshopScheduleRequest,
	BeginnersWorkshopSettingsRequest,
	BeginnersWorkshopStaffRequest,
	BeginnersWorkshopWithdrawRequest,
	WaitlistEntryCreateRequest,
} from "@dhc/api-client";
import * as v from "valibot";
import {
	ATTENDANCE_CORRECTIONS,
	INTAKE_BUTTON_COMMANDS,
} from "#lib/beginners-workshops/console.js";
import { waitlistRegistrationEntries } from "#lib/schemas/beginnersWaitlist.js";
import {
	civilDate,
	euroAmountInCents,
	guardianRules,
	optionalCivilDate,
	optionalPrincipalId,
	principalIds,
	wallTime,
	wholeNumber,
} from "#lib/schemas/fields.js";

/** The `{{venue}}` placeholder maximum, which Phoenix enforces too. */
export const VENUE_MAX = 80;

/** How many workshops one Schedule submission may carry. */
export const MAX_SCHEDULED_AT_ONCE = 20;

const settingsEntries = {
	capacity: wholeNumber("Capacity must be at least 1."),
	fee: euroAmountInCents("Enter the fee in euro."),
	paymentWindowDays: wholeNumber("The payment window is at least 1 day."),
};

/** ALE-379: one coach (optional) and any assistants, as Member picks. */
const staffEntries = {
	coachPrincipalId: optionalPrincipalId("Pick a coach from the list."),
	assistantPrincipalIds: principalIds("Pick assistants from the list."),
};

const venue = v.pipe(
	v.string(),
	v.trim(),
	v.nonEmpty("Enter the venue."),
	v.maxLength(VENUE_MAX, `The venue can be at most ${VENUE_MAX} characters.`),
);

const scheduleEntries = {
	venue,
	startTime: wallTime("Enter the start time."),
	...settingsEntries,
	workshops: v.pipe(
		v.array(
			v.object({
				date: civilDate("Pick the workshop date."),
				paymentCutoffDate: optionalCivilDate("Pick a valid cutoff date."),
				contactFromDate: optionalCivilDate("Pick a valid contact-from date."),
			}),
		),
		v.minLength(1, "Add at least one date."),
		v.maxLength(
			MAX_SCHEDULED_AT_ONCE,
			`Schedule at most ${MAX_SCHEDULED_AT_ONCE} workshops at once.`,
		),
	),
	...staffEntries,
};

/**
 * Schedule one or several workshops that share a venue, start time,
 * capacity, fee, window length and optional Staff; each date may override
 * its cutoff date and contact-from date.
 */
export const scheduleWorkshopsSchema = v.pipe(
	v.object(scheduleEntries),
	v.transform(
		({
			workshops,
			venue,
			startTime,
			capacity,
			fee,
			paymentWindowDays,
			coachPrincipalId,
			assistantPrincipalIds,
		}) =>
			({
				workshops: workshops.map((workshop) => ({
					...workshop,
					venue,
					startTime,
					capacity,
					feeCents: fee,
					paymentWindowDays,
					coachPrincipalId,
					assistantPrincipalIds,
				})),
			}) satisfies BeginnersWorkshopScheduleRequest,
	),
);

/**
 * The Capacity / fee / cutoff dialog. `contactFromDate` is only rendered
 * while Batch 1 has not gone out, so a missing value keeps Phoenix's.
 */
export const workshopSettingsSchema = v.pipe(
	v.object({
		id: v.pipe(v.string(), v.uuid("Unknown workshop.")),
		...settingsEntries,
		paymentCutoffDate: civilDate("Pick the cutoff date."),
		paymentCutoffTime: wallTime("Enter the cutoff time."),
		contactFromDate: optionalCivilDate("Pick a valid contact-from date."),
	}),
	v.transform(({ id, fee, ...settings }) => ({
		id,
		body: {
			...settings,
			feeCents: fee,
		} satisfies BeginnersWorkshopSettingsRequest,
	})),
);

/**
 * ALE-380: Pause or Resume automatic Batches. The form carries only the
 * workshop; Phoenix records who and when, and is idempotent.
 */
export const batchesCommandSchema = v.object({
	id: v.pipe(v.string(), v.uuid("Unknown workshop.")),
});

/** ALE-390: one person's door check-in (or its undo). */
export const doorCheckInSchema = v.object({
	id: v.pipe(v.string(), v.uuid("Unknown workshop.")),
	intakeId: v.pipe(v.string(), v.uuid("Unknown person.")),
});

/** ALE-391: Finish workshop (Attendance Finalisation) from the door. */
export const doorFinishSchema = v.object({
	id: v.pipe(v.string(), v.uuid("Unknown workshop.")),
});

export type ScheduleWorkshopsInput = v.InferInput<
	typeof scheduleWorkshopsSchema
>;
export type WorkshopSettingsInput = v.InferInput<typeof workshopSettingsSchema>;

/**
 * ALE-379: the Staff dialog. Replaces the whole Staff list; Phoenix drops a
 * coach from the assistants and checks who may be assigned.
 */
export const workshopStaffSchema = v.pipe(
	v.object({
		id: v.pipe(v.string(), v.uuid("Unknown workshop.")),
		...staffEntries,
	}),
	v.transform(({ id, coachPrincipalId, assistantPrincipalIds }) => ({
		id,
		body: {
			coachPrincipalId,
			assistantPrincipalIds,
		} satisfies BeginnersWorkshopStaffRequest,
	})),
);

export type WorkshopStaffInput = v.InferInput<typeof workshopStaffSchema>;

const workshopId = v.pipe(v.string(), v.uuid("Unknown workshop."));

/**
 * ALE-384: fast-track one Waitlist person (waiting, or removed within the
 * 3-month window) into a workshop. Phoenix decides eligibility under the lock.
 */
export const fastTrackWaitlistPersonSchema = v.pipe(
	v.object({
		id: workshopId,
		waitlistId: v.pipe(v.string(), v.uuid("Pick someone from the list.")),
	}),
	v.transform(({ id, waitlistId }) => ({
		id,
		body: { waitlistId } satisfies BeginnersWorkshopFastTrackRequest,
	})),
);

/**
 * ALE-394: the Reschedule dialog. The dialog prefills the cutoff and (while
 * Batch 1 hasn't gone out) the contact-from date with the offsets Phoenix
 * keeps; Phoenix judges every cross-field rule.
 */
export const rescheduleWorkshopSchema = v.pipe(
	v.object({
		id: workshopId,
		date: civilDate("Pick the new date."),
		startTime: wallTime("Enter the start time."),
		venue,
		paymentCutoffDate: civilDate("Pick the cutoff date."),
		paymentCutoffTime: wallTime("Enter the cutoff time."),
		contactFromDate: optionalCivilDate("Pick a valid contact-from date."),
	}),
	v.transform(({ id, ...body }) => ({
		id,
		body: body satisfies BeginnersWorkshopRescheduleRequest,
	})),
);

export type RescheduleWorkshopInput = v.InferInput<
	typeof rescheduleWorkshopSchema
>;

/**
 * ALE-395: Cancel the workshop, with an optional reason kept on the
 * workshop and each Intake's history.
 */
export const cancelWorkshopSchema = v.pipe(
	v.object({
		id: workshopId,
		reason: v.optional(
			v.pipe(
				v.string(),
				v.trim(),
				v.maxLength(500, "Keep the reason under 500 characters."),
			),
			"",
		),
	}),
	v.transform(({ id, reason }) => ({
		id,
		body: (reason ? { reason } : {}) satisfies BeginnersWorkshopCancelRequest,
	})),
);

const newPersonEntries = { id: workshopId, ...waitlistRegistrationEntries };

/**
 * ALE-384: "Not on the Waitlist? Add them" — the public registration form,
 * sent through the staff path (works while registration is closed), then the
 * same Fast-track. The output body is the registration request.
 */
export const fastTrackNewPersonSchema = v.pipe(
	v.object(newPersonEntries),
	...guardianRules<
		v.InferOutput<v.ObjectSchema<typeof newPersonEntries, undefined>>
	>(),
	v.transform(({ id, ...body }) => ({
		id,
		body: body satisfies WaitlistEntryCreateRequest,
	})),
);

export type FastTrackNewPersonInput = v.InferInput<
	typeof fastTrackNewPersonSchema
>;

const refundId = v.pipe(v.string(), v.uuid("Unknown refund."));

/**
 * ALE-392: send one attended person their Invitation, from the console's
 * attended list or the Invitable view.
 */
export const inviteAttendeeSchema = v.object({
	id: workshopId,
	intakeId: v.pipe(v.string(), v.uuid("Unknown person.")),
});

/** ALE-382: Retry a failed refund from Needs attention. */
export const retryRefundSchema = v.object({ id: workshopId, refundId });

/**
 * ALE-382: Record manual refund — the coordinator paid the person back
 * outside Stripe. The optional note says how; a blank note is left out.
 */
export const recordManualRefundSchema = v.pipe(
	v.object({
		id: workshopId,
		refundId,
		note: v.optional(
			v.pipe(
				v.string(),
				v.trim(),
				v.maxLength(500, "Keep the note under 500 characters."),
			),
			"",
		),
	}),
	v.transform(({ id, refundId, note }) => ({
		id,
		refundId,
		body: (note ? { note } : {}) satisfies BeginnersWorkshopManualRefundRequest,
	})),
);

const intakeId = v.pipe(v.string(), v.uuid("Unknown Intake."));

/**
 * ALE-386: one console Intake command. Each command is a submit button of
 * the same form (`command`), so the Intake's one optional note goes with
 * whichever is pressed; a blank note is left out.
 */
export const intakeCommandSchema = v.pipe(
	v.object({
		id: workshopId,
		intakeId,
		command: v.picklist(INTAKE_BUTTON_COMMANDS, "Unknown command."),
		note: v.optional(
			v.pipe(
				v.string(),
				v.trim(),
				v.maxLength(500, "Keep the note under 500 characters."),
			),
			"",
		),
	}),
	v.transform(({ id, intakeId, command, note }) => ({
		id,
		intakeId,
		command,
		body: (note
			? { note }
			: {}) satisfies BeginnersWorkshopIntakeCommandRequest,
	})),
);

/**
 * ALE-393: correct an Intake's attendance after finalisation. The pressed
 * button is the target (`to`), so the note goes with whichever is pressed.
 */
export const correctAttendanceSchema = v.pipe(
	v.object({
		id: workshopId,
		intakeId,
		to: v.picklist(ATTENDANCE_CORRECTIONS, "Unknown correction."),
		note: v.optional(
			v.pipe(
				v.string(),
				v.trim(),
				v.maxLength(500, "Keep the note under 500 characters."),
			),
			"",
		),
	}),
	v.transform(({ id, intakeId, to, note }) => ({
		id,
		intakeId,
		body: (note
			? { to, note }
			: { to }) satisfies BeginnersWorkshopCorrectAttendanceRequest,
	})),
);

/**
 * ALE-387: the refund-or-forfeit choice. Phoenix requires it whenever the
 * person has a paid Intake (`refund_choice_required`) and ignores it
 * otherwise, so it is optional here.
 */
const refundChoice = v.optional(
	v.picklist(["refund", "forfeit"], "Choose refund or forfeit."),
);

const withdrawNote = v.optional(
	v.pipe(
		v.string(),
		v.trim(),
		v.maxLength(500, "Keep the note under 500 characters."),
	),
	"",
);

function withdrawBody(
	refund: "refund" | "forfeit" | undefined,
	note: string,
): BeginnersWorkshopWithdrawRequest {
	const body: BeginnersWorkshopWithdrawRequest = {};
	if (refund) body.refund = refund === "refund";
	if (note) body.note = note;
	return body;
}

/** ALE-387: Withdraw from the console's Intake detail. */
export const withdrawIntakeSchema = v.pipe(
	v.object({
		id: workshopId,
		intakeId,
		refund: refundChoice,
		note: withdrawNote,
	}),
	v.transform(({ id, intakeId, refund, note }) => ({
		id,
		intakeId,
		body: withdrawBody(refund, note),
	})),
);

/** ALE-387: Withdraw from the Waitlist tab, which names the person. */
export const withdrawPersonSchema = v.pipe(
	v.object({
		waitlistId: v.pipe(v.string(), v.uuid("Unknown person.")),
		refund: refundChoice,
		note: withdrawNote,
	}),
	v.transform(({ waitlistId, refund, note }) => ({
		waitlistId,
		body: withdrawBody(refund, note),
	})),
);
