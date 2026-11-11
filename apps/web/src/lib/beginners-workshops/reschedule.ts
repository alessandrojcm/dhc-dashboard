/**
 * ALE-394: the Reschedule dialog's prefill and warning. Phoenix decides the
 * reschedule (`reschedule_workshop`); this module only proposes the same
 * kept offsets so the dialog opens — and follows a new date or time — with
 * the values Phoenix would keep:
 *
 * - the Payment Cutoff keeps its Dublin civil offset before the start;
 * - while Batch 1 hasn't gone out, the contact-from date keeps its days
 *   before the workshop date, or comes forward to Dublin today when that
 *   would fall after the cutoff date.
 *
 * ALE-441: the same dialog edits the destination details. A submission that
 * keeps the date, times and venue but changes the destination is a
 * destination-only change (`update_destination`), which Phoenix never treats
 * as a reschedule.
 */
import type {
	BeginnersWorkshop,
	BeginnersWorkshopConsole,
} from "@dhc/api-client";
import {
	type DestinationFields,
	destinationBody,
	destinationValues,
} from "#lib/destinations.js";

/** A Dublin civil date (`YYYY-MM-DD`) and wall time (`HH:MM`). */
export interface CivilDateTime {
	date: string;
	time: string;
}

/** A civil date and wall time as minutes since the epoch, ignoring zones. */
function civilMinutes(date: string, time: string): number {
	const [year, month, day] = date.split("-").map(Number);
	const [hour, minute] = time.split(":").map(Number);
	return Date.UTC(year, month - 1, day, hour, minute) / 60_000;
}

function civilFromMinutes(minutes: number): CivilDateTime {
	const iso = new Date(minutes * 60_000).toISOString();
	return { date: iso.slice(0, 10), time: iso.slice(11, 16) };
}

function addDays(date: string, days: number): string {
	return civilFromMinutes(civilMinutes(date, "00:00") + days * 1440).date;
}

function daysBetween(from: string, to: string): number {
	return Math.round(
		(civilMinutes(to, "00:00") - civilMinutes(from, "00:00")) / 1440,
	);
}

/** The cutoff date and time that keep the current offset before a new start. */
export function keptCutoff(
	workshop: Pick<
		BeginnersWorkshop,
		"date" | "startTime" | "paymentCutoffDate" | "paymentCutoffTime"
	>,
	date: string,
	startTime: string,
): CivilDateTime {
	const offset =
		civilMinutes(workshop.date, workshop.startTime) -
		civilMinutes(workshop.paymentCutoffDate, workshop.paymentCutoffTime);
	return civilFromMinutes(civilMinutes(date, startTime) - offset);
}

/**
 * The contact-from date that keeps its days before a new date, or `today`
 * when that would fall after the cutoff date.
 */
export function keptContactFrom(
	workshop: Pick<BeginnersWorkshop, "date" | "contactFromDate">,
	date: string,
	cutoffDate: string,
	today: string,
): string {
	const kept = addDays(
		date,
		-daysBetween(workshop.contactFromDate, workshop.date),
	);
	return kept > cutoffDate ? today : kept;
}

/** What one Reschedule dialog submission asks Phoenix to do. */
export type RescheduleOperation = "reschedule" | "destination";

/** The schedule values the Reschedule dialog submits. */
export interface ScheduleValues {
	date: string;
	startTime: string;
	endTime: string;
	venue: string;
}

const wall = (time: string | null | undefined) => (time ?? "").slice(0, 5);

/**
 * A reschedule when the date, start time, end time or venue changes (the
 * fields `reschedule_workshop` counts as a move). Otherwise a changed
 * destination is a destination-only change; with nothing changed at all the
 * dialog stays a reschedule, which Phoenix refuses as no move. A legacy
 * workshop with no end time is moved by any explicit end.
 */
export function rescheduleOperation(
	workshop: Pick<
		BeginnersWorkshop,
		| "date"
		| "startTime"
		| "endTime"
		| "venue"
		| "destinationName"
		| "destinationAddress"
		| "directionsUrl"
		| "destinationProvider"
		| "destinationPlaceId"
	>,
	values: ScheduleValues & DestinationFields,
): RescheduleOperation {
	const moved =
		values.date !== workshop.date ||
		wall(values.startTime) !== wall(workshop.startTime) ||
		wall(values.endTime) !== wall(workshop.endTime) ||
		values.venue.trim() !== workshop.venue;
	if (moved) return "reschedule";

	const saved = destinationBody(destinationValues(workshop));
	const next = destinationBody(values);
	const changed =
		next.destinationName !== saved.destinationName ||
		next.destinationAddress !== saved.destinationAddress ||
		next.directionsUrl !== saved.directionsUrl ||
		// ALE-442: selecting, replacing or removing a Google place.
		next.destinationPlaceId !== saved.destinationPlaceId;
	return changed ? "destination" : "reschedule";
}

/** Who a reschedule emails: every open Intake (paid or asked). */
export function rescheduleRecipients(view: BeginnersWorkshopConsole): number {
	return view.roster.seated.length + view.roster.asked.length;
}

/** The warning shown before saving. */
export function rescheduleWarning(
	recipients: number,
	operation: RescheduleOperation = "reschedule",
): string {
	if (operation === "destination")
		return "No emails will be sent: only the destination details change.";
	if (recipients === 0)
		return "No emails will be sent: nobody has an active workshop place.";
	const people = recipients === 1 ? "1 person" : `${recipients} people`;
	return `This emails ${people} “Workshop rescheduled”.`;
}
