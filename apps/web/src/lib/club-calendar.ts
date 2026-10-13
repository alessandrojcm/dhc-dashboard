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
const CLUB_TIME_ZONE = "Europe/Dublin";

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

/** Reads an instant's parts in `format`, by part type. */
function partsOf(format: Intl.DateTimeFormat, iso: string) {
	const byType = new Map(
		format.formatToParts(new Date(iso)).map((part) => [part.type, part.value]),
	);
	return (type: Intl.DateTimeFormatPartTypes) => byType.get(type) ?? "";
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
	const part = partsOf(dublinInstantParts, iso);
	return `${part("weekday")} ${part("day")} ${part("month")}, ${part("hour")}:${part("minute")}`;
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

// en-US names match the English short and long names the dashboard has always
// shown (`Sep`, not en-IE's `Sept`); the zone, not the locale, makes them
// Dublin's.
const dublinClockParts = new Intl.DateTimeFormat("en-US", {
	timeZone: CLUB_TIME_ZONE,
	year: "numeric",
	month: "2-digit",
	day: "2-digit",
	hour: "2-digit",
	minute: "2-digit",
	hourCycle: "h23",
});
const dublinShortNames = new Intl.DateTimeFormat("en-US", {
	timeZone: CLUB_TIME_ZONE,
	weekday: "short",
	month: "short",
});
const dublinLongNames = new Intl.DateTimeFormat("en-US", {
	timeZone: CLUB_TIME_ZONE,
	weekday: "long",
	month: "long",
});

/** The Dublin wall clock reading of an instant. */
function dublinClock(iso: string) {
	const clock = partsOf(dublinClockParts, iso);
	const short = partsOf(dublinShortNames, iso);
	const long = partsOf(dublinLongNames, iso);
	const hour = Number(clock("hour"));
	const minute = clock("minute");
	return {
		isoDate: `${clock("year")}-${clock("month")}-${clock("day")}`,
		year: clock("year"),
		day: String(Number(clock("day"))),
		hour: clock("hour"),
		minute,
		// Derived from the 24-hour reading rather than a separate h12 format,
		// so the hour and the wall-clock date can never disagree.
		time12h: `${((hour + 11) % 12) + 1}:${minute} ${hour < 12 ? "AM" : "PM"}`,
		weekday: short("weekday"),
		month: short("month"),
		weekdayLong: long("weekday"),
		monthLong: long("month"),
	};
}

/** An instant's Dublin day: `12 Oct 2026`. */
export function formatDublinDate(iso: string): string {
	const { day, month, year } = dublinClock(iso);
	return `${day} ${month} ${year}`;
}

/** An instant's Dublin day in full: `Tuesday, 20 October 2026`. */
export function formatDublinDateLong(iso: string): string {
	const { weekdayLong, day, monthLong, year } = dublinClock(iso);
	return `${weekdayLong}, ${day} ${monthLong} ${year}`;
}

/** The calendar tile parts of an instant's Dublin day: `Tue` / `20` / `Oct`. */
export function dublinInstantTile(iso: string) {
	const { weekday, day, month } = dublinClock(iso);
	return { weekday, day, month };
}

/** An instant as Dublin 12-hour time: `6:30 PM`. */
export function formatDublinTime12h(iso: string): string {
	return dublinClock(iso).time12h;
}

/**
 * An instant's Dublin day and 12-hour time: `Tue, 20 Oct · 6:30 PM`, or
 * `Tue, 20 Oct 2026 · 6:30 PM` with `withYear`.
 */
export function formatDublinDayAndTime(
	iso: string,
	{ withYear = false }: { withYear?: boolean } = {},
): string {
	const { weekday, day, month, year, time12h } = dublinClock(iso);
	return `${weekday}, ${day} ${month}${withYear ? ` ${year}` : ""} · ${time12h}`;
}

/**
 * A club event's span. One that starts and ends on the same Dublin day names
 * it once (`Tue, 20 Oct · 6:30 PM–8:30 PM`); otherwise each end carries its
 * own day (`14 Jul · 11:30 PM–15 Jul · 12:30 AM`).
 */
export function formatDublinSpan(startIso: string, endIso: string): string {
	const start = dublinClock(startIso);
	const end = dublinClock(endIso);
	if (start.isoDate === end.isoDate) {
		return `${start.weekday}, ${start.day} ${start.month} · ${start.time12h}–${end.time12h}`;
	}
	return `${start.day} ${start.month} · ${start.time12h}–${end.day} ${end.month} · ${end.time12h}`;
}

/**
 * An instant as the zone-less Dublin wall clock reading `YYYY-MM-DD HH:mm`,
 * which a calendar component reads as local time, so the event lands on the
 * Dublin day and hour whatever the reader's own zone.
 */
export function dublinWallClock(iso: string): string {
	const { isoDate, hour, minute } = dublinClock(iso);
	return `${isoDate} ${hour}:${minute}`;
}

/**
 * The instant at which Dublin's wall clock reads `time` (`HH:MM`, or
 * `HH:MM:SS` as a `type="time"` input with seconds gives it) on the civil
 * `date` (`YYYY-MM-DD`), as an ISO timestamp: the inverse of
 * `dublinWallClock`.
 *
 * Clock changes use the `compatible` disambiguation (Temporal's default): a
 * time the spring-forward night skips moves forward by the gap (01:30 on 29
 * Mar 2026 is 02:30 IST), and a time the fall-back night repeats takes the
 * earlier, summer offset (01:30 on 25 Oct 2026 is 01:30 IST). An empty or
 * unreadable date or time returns `undefined` rather than throwing.
 *
 * Worked out with `Intl` alone: `@internationalized/date`'s `toZoned` takes a
 * shortcut through the host's `Date` when the zone is the cached local one,
 * so it answers wrongly once the host zone changes under it (as tests do).
 */
export function dublinInstant(date: string, time: string): string | undefined {
	const wall = wallClockAsUtc(date, time);
	if (wall === undefined) return undefined;
	// Temporal's possible-instants rule: an offset in force a day either side
	// covers every Dublin transition. Each offset that reproduces the wall
	// clock gives a candidate; two mean a repeated hour, none a skipped one.
	const before = dublinOffsetAt(wall - DAY_MS);
	const after = dublinOffsetAt(wall + DAY_MS);
	const candidates = [wall - before, wall - after].filter(
		(instant) => wall - instant === dublinOffsetAt(instant),
	);
	// `compatible`: the earlier of a repeated time; a skipped time keeps the
	// offset from before the gap, which lands it after the gap.
	const instant =
		candidates.length > 0 ? Math.min(...candidates) : wall - before;
	return new Date(instant).toISOString();
}

const DAY_MS = 24 * 60 * 60 * 1000;

const dublinOffsetParts = new Intl.DateTimeFormat("en-US", {
	timeZone: CLUB_TIME_ZONE,
	year: "numeric",
	month: "2-digit",
	day: "2-digit",
	hour: "2-digit",
	minute: "2-digit",
	second: "2-digit",
	hourCycle: "h23",
});

/** Dublin's offset from UTC at an instant, in milliseconds. */
function dublinOffsetAt(instant: number): number {
	const part = partsOf(dublinOffsetParts, new Date(instant).toISOString());
	const wall = Date.UTC(
		Number(part("year")),
		Number(part("month")) - 1,
		Number(part("day")),
		Number(part("hour")),
		Number(part("minute")),
		Number(part("second")),
	);
	// The formatter reads whole seconds, so compare against the whole second.
	return wall - Math.floor(instant / 1000) * 1000;
}

/**
 * A civil date and wall-clock time as if it were UTC, in milliseconds, or
 * `undefined` when either is not a real date or time. Built with `Date.UTC`,
 * never the host's own zone.
 */
function wallClockAsUtc(date: string, time: string): number | undefined {
	const day = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
	const clock = /^(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(time);
	if (!day || !clock) return undefined;
	const [year, month, dayOfMonth] = day.slice(1).map(Number);
	const [hour, minute, second = 0] = clock
		.slice(1)
		.filter((value) => value !== undefined)
		.map(Number);
	if (hour > 23 || minute > 59 || second > 59) return undefined;
	const wall = Date.UTC(year, month - 1, dayOfMonth, hour, minute, second);
	// Date.UTC rolls an impossible day (30 Feb) over; refuse it instead.
	return new Date(wall).toISOString().startsWith(date) ? wall : undefined;
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
