import { CalendarDate, CalendarDateTime } from "@internationalized/date";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
	civilCalendarDate,
	civilDateTile,
	civilIsoDate,
	dublinInstantTile,
	dublinToday,
	dublinTodayCalendarDate,
	dublinWallClock,
	formatCivilDate,
	formatCivilDateLong,
	formatDublinDate,
	formatDublinDateLong,
	formatDublinDayAndTime,
	formatDublinInstant,
	formatDublinSpan,
	formatDublinTime,
	formatDublinTime12h,
	formatDublinTimestamp,
} from "#lib/club-calendar.js";

// 2026's clock changes: Dublin moves to IST (UTC+1) at 01:00 UTC on Sunday
// 29 March and back to GMT at 01:00 UTC on Sunday 25 October.
describe("on the Dublin clock", () => {
	it("knows Dublin's today on either side of midnight", () => {
		expect(dublinToday(new Date("2026-01-14T23:30:00Z"))).toBe("2026-01-14");
		expect(dublinToday(new Date("2026-07-14T23:30:00Z"))).toBe("2026-07-15");
		expect(dublinTodayCalendarDate(new Date("2026-07-14T23:30:00Z"))).toEqual(
			new CalendarDate(2026, 7, 15),
		);
	});

	it("follows the last Sunday of March into Irish Summer Time", () => {
		expect(formatDublinTime("2026-03-29T00:59:00Z")).toBe("00:59");
		expect(formatDublinTime("2026-03-29T01:00:00Z")).toBe("02:00");
		expect(dublinToday(new Date("2026-03-28T23:30:00Z"))).toBe("2026-03-28");
		expect(dublinToday(new Date("2026-03-29T23:30:00Z"))).toBe("2026-03-30");
	});

	it("follows the last Sunday of October back to GMT", () => {
		expect(formatDublinTime("2026-10-25T00:59:00Z")).toBe("01:59");
		expect(formatDublinTime("2026-10-25T01:00:00Z")).toBe("01:00");
		expect(formatDublinInstant("2026-10-24T23:30:00Z")).toBe(
			"Sun 25 Oct, 00:30",
		);
		expect(formatDublinInstant("2026-10-25T23:30:00Z")).toBe(
			"Sun 25 Oct, 23:30",
		);
		expect(dublinToday(new Date("2026-10-25T23:30:00Z"))).toBe("2026-10-25");
	});

	it("words an instant as weekday, date and 24-hour time", () => {
		expect(formatDublinInstant("2026-10-20T09:00:00Z")).toBe(
			"Tue 20 Oct, 10:00",
		);
		expect(formatDublinInstant("2026-10-28T10:00:00Z")).toBe(
			"Wed 28 Oct, 10:00",
		);
		expect(formatDublinInstant("2026-12-01T18:05:00Z")).toBe(
			"Tue 1 Dec, 18:05",
		);
	});

	it("words a timestamp with its year", () => {
		expect(formatDublinTimestamp("2026-10-12T13:30:00Z")).toBe(
			"12 Oct 2026, 14:30",
		);
		expect(formatDublinTimestamp("2026-01-05T09:05:00Z")).toBe(
			"5 Jan 2026, 09:05",
		);
	});
});

describe("club event instants on the Dublin clock", () => {
	it("words an instant's Dublin day", () => {
		expect(formatDublinDate("2026-10-12T13:30:00Z")).toBe("12 Oct 2026");
		expect(formatDublinDate("2026-09-01T23:30:00Z")).toBe("2 Sep 2026");
		expect(formatDublinDateLong("2026-10-20T17:30:00Z")).toBe(
			"Tuesday, 20 October 2026",
		);
		expect(dublinInstantTile("2026-09-01T23:30:00Z")).toEqual({
			weekday: "Wed",
			day: "2",
			month: "Sep",
		});
	});

	it("words a time of day on the 12-hour clock", () => {
		expect(formatDublinTime12h("2026-10-20T17:30:00Z")).toBe("6:30 PM");
		expect(formatDublinTime12h("2026-10-20T11:05:00Z")).toBe("12:05 PM");
		expect(formatDublinTime12h("2026-12-20T00:15:00Z")).toBe("12:15 AM");
		expect(formatDublinTime12h("2026-12-20T09:00:00Z")).toBe("9:00 AM");
	});

	it("words a day and time, with the year when asked", () => {
		expect(formatDublinDayAndTime("2026-10-20T17:30:00Z")).toBe(
			"Tue, 20 Oct · 6:30 PM",
		);
		expect(
			formatDublinDayAndTime("2026-10-20T17:30:00Z", { withYear: true }),
		).toBe("Tue, 20 Oct 2026 · 6:30 PM");
	});

	it("words a span, naming the day once when it starts and ends on the same Dublin day", () => {
		expect(
			formatDublinSpan("2026-10-20T17:30:00Z", "2026-10-20T19:30:00Z"),
		).toBe("Tue, 20 Oct · 6:30 PM–8:30 PM");
		// 22:30–23:30 UTC is one UTC day but crosses midnight in Irish Summer Time.
		expect(
			formatDublinSpan("2026-07-14T22:30:00Z", "2026-07-14T23:30:00Z"),
		).toBe("14 Jul · 11:30 PM–15 Jul · 12:30 AM");
	});

	it("places an event on the Dublin wall clock across the October change", () => {
		expect(dublinWallClock("2026-10-24T09:00:00Z")).toBe("2026-10-24 10:00");
		expect(dublinWallClock("2026-10-25T09:00:00Z")).toBe("2026-10-25 09:00");
		expect(dublinWallClock("2026-03-29T00:30:00Z")).toBe("2026-03-29 00:30");
		expect(dublinWallClock("2026-03-29T01:30:00Z")).toBe("2026-03-29 02:30");
	});
});

describe("civil dates", () => {
	it("words a civil date as given", () => {
		expect(formatCivilDate("2026-11-14")).toBe("Sat 14 Nov 2026");
		expect(formatCivilDateLong("2026-10-08")).toBe("Thursday 8 October 2026");
		expect(civilDateTile("2026-03-29")).toEqual({
			weekday: "Sun",
			day: "29",
			month: "Mar",
		});
	});

	it("bridges a civil date to the date picker and back", () => {
		expect(civilCalendarDate("2026-03-29")).toEqual(
			new CalendarDate(2026, 3, 29),
		);
		expect(civilIsoDate(new CalendarDate(2026, 10, 25))).toBe("2026-10-25");
	});

	it("leaves an empty or unreadable date unset instead of throwing", () => {
		expect(civilCalendarDate("")).toBeUndefined();
		expect(civilCalendarDate("not a date")).toBeUndefined();
		expect(civilCalendarDate("2026-02-30")).toBeUndefined();
		expect(civilIsoDate(undefined)).toBe("");
		expect(civilIsoDate(new CalendarDateTime(2026, 10, 25, 9, 0))).toBe("");
	});
});

describe("on a host west of Dublin", () => {
	const hostZone = process.env.TZ;

	beforeAll(() => {
		process.env.TZ = "America/Los_Angeles";
	});

	afterAll(() => {
		process.env.TZ = hostZone;
	});

	it("runs in that zone", () => {
		// Guards the rest of the block: without it, a runner that ignores TZ
		// changes would pass for the wrong reason.
		expect(new Date("2026-10-12T12:00:00Z").getTimezoneOffset()).toBe(420);
	});

	it("keeps the civil day it was given", () => {
		expect(formatCivilDate("2026-03-29")).toBe("Sun 29 Mar 2026");
		expect(formatCivilDateLong("2026-10-25")).toBe("Sunday 25 October 2026");
		expect(civilDateTile("2026-10-25")).toEqual({
			weekday: "Sun",
			day: "25",
			month: "Oct",
		});
		expect(civilCalendarDate("2026-10-25")).toEqual(
			new CalendarDate(2026, 10, 25),
		);
	});

	it("still reads instants on the Dublin clock", () => {
		expect(dublinToday(new Date("2026-10-25T06:30:00Z"))).toBe("2026-10-25");
		expect(dublinToday(new Date("2026-10-24T23:30:00Z"))).toBe("2026-10-25");
		expect(formatDublinTime("2026-10-25T00:59:00Z")).toBe("01:59");
		expect(formatDublinInstant("2026-03-29T01:00:00Z")).toBe(
			"Sun 29 Mar, 02:00",
		);
	});

	it("still words a club event's day and time on the Dublin clock", () => {
		// 18:30 Dublin is 10:30 in Los Angeles; 23:30 UTC is the next Dublin day.
		expect(formatDublinDayAndTime("2026-10-20T17:30:00Z")).toBe(
			"Tue, 20 Oct · 6:30 PM",
		);
		expect(formatDublinDate("2026-07-14T23:30:00Z")).toBe("15 Jul 2026");
		expect(dublinInstantTile("2026-07-14T23:30:00Z")).toEqual({
			weekday: "Wed",
			day: "15",
			month: "Jul",
		});
		expect(dublinWallClock("2026-10-25T09:00:00Z")).toBe("2026-10-25 09:00");
	});
});
