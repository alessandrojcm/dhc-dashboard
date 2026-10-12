/**
 * The Club Calendar: the club's one zone, its today and how the dashboard
 * words Dublin dates and times. No other module keeps its own copy
 * (`CONTEXT.md`), so every context avoids the same day-shift trap the same way.
 *
 * Two kinds of value pass through here:
 * - **Instants** (ISO timestamps from Phoenix) are shown on the Europe/Dublin
 *   wall clock, whatever the reader's own zone.
 * - **Civil dates** (`YYYY-MM-DD`) are already Dublin days. They are formatted
 *   and bridged to the date picker as given, never through `new Date(iso)` or
 *   `fromDate`, which would read them as an instant in the reader's zone and
 *   shift the day for anyone west of UTC.
 */
import {
	CalendarDate,
	parseDate,
	type DateValue,
} from "@internationalized/date";
import dayjs from "dayjs";

/** The Club Calendar's zone. */
export const CLUB_TIME_ZONE = "Europe/Dublin";

const dublinDate = new Intl.DateTimeFormat("en-CA", {
	timeZone: CLUB_TIME_ZONE,
	year: "numeric",
	month: "2-digit",
	day: "2-digit",
});

/** Today's Dublin civil date, `YYYY-MM-DD`. */
export function dublinToday(now: Date = new Date()): string {
	// en-CA formats as an ISO date, so the result never depends on the host's
	// locale settings.
	return dublinDate.format(now);
}

/** Today's Dublin civil date as the date picker's `CalendarDate`. */
export function dublinTodayCalendarDate(now: Date = new Date()): CalendarDate {
	return parseDate(dublinToday(now));
}

/**
 * The `DateValue` the shared `date-picker.svelte` speaks, for a civil
 * `YYYY-MM-DD`.
 *
 * The string's own year, month and day become the `CalendarDate`, so the
 * civil day it names never moves. An empty or unreadable value (including an
 * impossible day such as `2026-02-30`) returns `undefined` rather than
 * throwing, so a cleared field still reaches Phoenix's own refusal instead of
 * crashing the picker.
 */
export function civilCalendarDate(isoDate: string): CalendarDate | undefined {
	try {
		return parseDate(isoDate);
	} catch {
		return undefined;
	}
}

/**
 * A picked date back as `YYYY-MM-DD`, or `""` when nothing is picked.
 *
 * `Calendar` is configured `type="single"` without a time zone, so it returns a
 * `CalendarDate` whose `toString()` is already the ISO date. The narrowing is
 * the guard, not a cast: a `ZonedDateTime` or `CalendarDateTime` reaching here
 * would stringify to something the API's `format: date` rejects.
 */
export function civilIsoDate(value: DateValue | undefined): string {
	return value instanceof CalendarDate ? value.toString() : "";
}

const dublinInstantParts = new Intl.DateTimeFormat("en-IE", {
	timeZone: CLUB_TIME_ZONE,
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
		dublinInstantParts
			.formatToParts(new Date(iso))
			.map((part) => [part.type, part.value]),
	);
	return `${parts.weekday} ${parts.day} ${parts.month}, ${parts.hour}:${parts.minute}`;
}

const dublinTime = new Intl.DateTimeFormat("en-IE", {
	timeZone: CLUB_TIME_ZONE,
	hour: "2-digit",
	minute: "2-digit",
	hourCycle: "h23",
});

/** An instant as Dublin `HH:MM`. */
export function formatDublinTime(iso: string): string {
	return dublinTime.format(new Date(iso));
}

const dublinTimestamp = new Intl.DateTimeFormat("en-IE", {
	dateStyle: "medium",
	timeStyle: "short",
	timeZone: CLUB_TIME_ZONE,
});

/** An instant with its year on the Dublin clock: `12 Oct 2026, 14:30`. */
export function formatDublinTimestamp(iso: string): string {
	return dublinTimestamp.format(new Date(iso));
}

/** A civil `YYYY-MM-DD` as `Sat 14 Nov 2026`. */
export function formatCivilDate(date: string): string {
	return dayjs(date).format("ddd D MMM YYYY");
}

/** The calendar tile parts of a civil date: `Sat` / `14` / `Nov`. */
export function civilDateTile(date: string) {
	const day = dayjs(date);
	return {
		weekday: day.format("ddd"),
		day: day.format("D"),
		month: day.format("MMM"),
	};
}

const civilDateLongParts = new Intl.DateTimeFormat("en-GB", {
	weekday: "long",
	day: "numeric",
	month: "long",
	year: "numeric",
	// The civil day is anchored at UTC midnight and read back in UTC, so the
	// weekday never shifts with the reader's own zone.
	timeZone: "UTC",
});

/**
 * A civil `YYYY-MM-DD` as `Thursday 8 October 2026`. Built from parts rather
 * than `format()` because en-GB inserts a comma after the weekday, while
 * Phoenix renders a Training Announcement's `{{date}}` as
 * `Thursday 25 September` — the sheet shows both, so they should read alike.
 */
export function formatCivilDateLong(date: string): string {
	const byType = new Map(
		civilDateLongParts
			.formatToParts(new Date(`${date}T00:00:00Z`))
			.map((part) => [part.type, part.value]),
	);
	const order: Intl.DateTimeFormatPartTypes[] = [
		"weekday",
		"day",
		"month",
		"year",
	];
	return order.map((type) => byType.get(type) ?? "").join(" ");
}
