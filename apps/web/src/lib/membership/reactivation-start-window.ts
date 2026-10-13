/**
 * The start dates the reactivation modal offers, reconciled with the window
 * Phoenix accepts.
 *
 * Phoenix judges a reactivation start date against its own **UTC** today:
 * `Dhc.Membership` accepts today up to 366 days ahead, and
 * `Dhc.Membership.Reactivation` treats a start after that UTC today as a
 * future start (the monthly charge waits for it, so nothing monthly is due
 * today). Dublin's today is the same day or one ahead (Irish Summer Time,
 * between 00:00 and 01:00), never behind. So the modal:
 *
 * - starts the window on Dublin's today, the later of the two: Phoenix
 *   accepts it, and staff are never offered a day that is already over in
 *   Dublin;
 * - ends it on Phoenix's own last day, UTC today + 366, which Phoenix accepts
 *   and Dublin's today + 366 can overshoot by one;
 * - asks "is this a future start?" on UTC today, as Phoenix does, so the
 *   wording of what is due today matches the amounts Phoenix returns.
 *
 * Billing dates are not worked out here: Phoenix returns them.
 */
import { type CalendarDate, parseDate } from "@internationalized/date";
import {
	civilCalendarDate,
	dublinTodayCalendarDate,
} from "#lib/club-calendar.js";

/** `Dhc.Membership`'s `@max_start_date_days_ahead`. */
export const MAX_START_DAYS_AHEAD = 366;

/** Phoenix's today: the UTC civil date of `now`. */
function utcToday(now: Date): CalendarDate {
	return parseDate(now.toISOString().slice(0, 10));
}

/** The first and last start dates the modal offers. */
export type ReactivationStartWindow = {
	earliest: CalendarDate;
	latest: CalendarDate;
};

/** The start dates to offer at `now`. */
export function reactivationStartWindow(
	now: Date = new Date(),
): ReactivationStartWindow {
	const phoenixToday = utcToday(now);
	const dublinToday = dublinTodayCalendarDate(now);

	return {
		earliest:
			dublinToday.compare(phoenixToday) > 0 ? dublinToday : phoenixToday,
		latest: phoenixToday.add({ days: MAX_START_DAYS_AHEAD }),
	};
}

/**
 * Whether Phoenix treats `startDate` (`YYYY-MM-DD`) as a future start at
 * `now`: the monthly charge is then due on that date, not today. An empty or
 * unreadable date is not a future start.
 */
export function isFutureStart(
	startDate: string,
	now: Date = new Date(),
): boolean {
	const date = civilCalendarDate(startDate);
	return date !== undefined && date.compare(utcToday(now)) > 0;
}
