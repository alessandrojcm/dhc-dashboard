import { CalendarDate } from "@internationalized/date";
import { describe, expect, it } from "vitest";
import {
	isFutureStart,
	reactivationStartWindow,
} from "#lib/membership/reactivation-start-window.js";

describe("the reactivation start window", () => {
	it("is Phoenix's UTC window when Dublin and UTC share a day", () => {
		expect(reactivationStartWindow(new Date("2026-01-14T23:30:00Z"))).toEqual({
			earliest: new CalendarDate(2026, 1, 14),
			latest: new CalendarDate(2027, 1, 15),
		});
	});

	it("starts on Dublin's today but ends on Phoenix's last day after Dublin's midnight in summer", () => {
		// 00:30 on 15 July in Dublin, still 14 July for Phoenix.
		expect(reactivationStartWindow(new Date("2026-07-14T23:30:00Z"))).toEqual({
			earliest: new CalendarDate(2026, 7, 15),
			latest: new CalendarDate(2027, 7, 15),
		});
	});

	it("judges a future start on Phoenix's UTC today", () => {
		const now = new Date("2026-07-14T23:30:00Z");

		expect(isFutureStart("2026-07-14", now)).toBe(false);
		// Dublin's today, yet after Phoenix's: Phoenix defers the monthly charge.
		expect(isFutureStart("2026-07-15", now)).toBe(true);
	});
});
