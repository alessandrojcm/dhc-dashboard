import { CalendarDate, CalendarDateTime } from "@internationalized/date";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
	civilCalendarDate,
	civilDateTile,
	civilIsoDate,
	dublinToday,
	dublinTodayCalendarDate,
	formatCivilDate,
	formatCivilDateLong,
	formatDublinInstant,
	formatDublinTime,
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
});
