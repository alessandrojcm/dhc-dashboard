/**
 * The Beginners' Workshop scheduling and settings forms (ALE-378), used for
 * both `form(...)` and `.preflight(...)`. Each output is the Phoenix request
 * the remote form sends unchanged. Phoenix applies every default (the cutoff
 * 3 days before, contact from today, a 7-day window) and every cross-field
 * rule; these schemas only check what one field can know on its own.
 */
import type {
	BeginnersWorkshopScheduleRequest,
	BeginnersWorkshopSettingsRequest,
	BeginnersWorkshopStaffRequest,
} from "@dhc/api-client";
import * as v from "valibot";
import {
	civilDate,
	euroAmountInCents,
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

const scheduleEntries = {
	venue: v.pipe(
		v.string(),
		v.trim(),
		v.nonEmpty("Enter the venue."),
		v.maxLength(VENUE_MAX, `The venue can be at most ${VENUE_MAX} characters.`),
	),
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
