/**
 * The `window` read model in calendar terms (ALE-332).
 *
 * Phoenix answers `GET /training-announcements/occurrences/window` with every
 * item on inclusive Dublin dates `from`/`to`: at most 62 dates, and never a
 * `from` before the 400-day retention horizon
 * (`Dhc.TrainingAnnouncements.retention_horizon/0`, shared with the delivery
 * pruner). This module translates event-calendar's `datesSet` range — whose
 * end is exclusive — into that inclusive window, and decides whether a range
 * may be asked for at all. The calendar refuses pre-horizon navigation with
 * an explanation instead of calling the API with an invalid `from`.
 */

/** How many Dublin dates of history Phoenix keeps, mirroring the backend. */
export const RETENTION_DAYS = 400;

export type WindowRange = {
	/** Inclusive Dublin date as `YYYY-MM-DD`. */
	from: string;
	/** Inclusive Dublin date as `YYYY-MM-DD`. */
	to: string;
};

function civilDate(isoDate: string): Date {
	// Anchored at UTC midnight so shifting never depends on the reader's own
	// time zone — the same anchor `announcement.ts` uses for civil dates.
	return new Date(`${isoDate}T00:00:00Z`);
}

function shiftDateIso(isoDate: string, days: number): string {
	const date = civilDate(isoDate);
	date.setUTCDate(date.getUTCDate() + days);
	return date.toISOString().slice(0, 10);
}

/** The earliest Dublin date `window` accepts, for a given Dublin today. */
export function retentionHorizon(today: string): string {
	return shiftDateIso(today, -RETENTION_DAYS);
}

function datePart(value: Date | string): string {
	if (value instanceof Date) {
		const year = value.getFullYear();
		const month = `${value.getMonth() + 1}`.padStart(2, "0");
		const day = `${value.getDate()}`.padStart(2, "0");
		return `${year}-${month}-${day}`;
	}
	return value.slice(0, 10);
}

/**
 * The inclusive `window` bounds for one `datesSet` callback. The calendar
 * reports the rendered grid with an exclusive end; the API wants both bounds
 * inclusive, so the end moves back one day.
 */
export function datesSetWindow(
	start: Date | string,
	end: Date | string,
): WindowRange {
	return { from: datePart(start), to: shiftDateIso(datePart(end), -1) };
}

/**
 * Whether `window` may be asked for this range. A `from` on the horizon is
 * allowed — only strictly earlier dates expired — so the comparison is
 * inclusive and the API is never called with an invalid `from`.
 */
export function windowAllowed(from: string, horizon: string): boolean {
	return from >= horizon;
}
