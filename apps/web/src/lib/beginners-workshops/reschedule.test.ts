import { describe, expect, it } from "vitest";
import {
	dublinToday,
	keptContactFrom,
	keptCutoff,
	rescheduleWarning,
} from "#lib/beginners-workshops/reschedule.js";

const workshop = {
	date: "2026-11-14",
	startTime: "18:30",
	paymentCutoffDate: "2026-11-11",
	paymentCutoffTime: "18:30",
	contactFromDate: "2026-10-20",
};

describe("keptCutoff", () => {
	it("keeps the offset before a new date and start time", () => {
		expect(keptCutoff(workshop, "2026-11-21", "19:00")).toEqual({
			date: "2026-11-18",
			time: "19:00",
		});
	});

	it("keeps an offset that is not whole days", () => {
		expect(
			keptCutoff(
				{
					...workshop,
					paymentCutoffDate: "2026-11-13",
					paymentCutoffTime: "12:00",
				},
				"2026-12-01",
				"10:00",
			),
		).toEqual({ date: "2026-11-30", time: "03:30" });
	});

	it("crosses a month end", () => {
		expect(keptCutoff(workshop, "2026-12-02", "18:30").date).toBe("2026-11-29");
	});
});

describe("keptContactFrom", () => {
	it("keeps its days before the new date", () => {
		expect(
			keptContactFrom(workshop, "2026-11-21", "2026-11-18", "2026-10-09"),
		).toBe("2026-10-27");
	});

	it("comes forward to today when it would fall after the cutoff date", () => {
		expect(
			keptContactFrom(
				{ date: "2026-11-14", contactFromDate: "2026-11-10" },
				"2026-11-12",
				"2026-11-01",
				"2026-10-09",
			),
		).toBe("2026-10-09");
	});
});

describe("dublinToday", () => {
	it("is the Dublin date, not UTC's", () => {
		// 23:30 UTC on 9 October is 00:30 on 10 October in Dublin (IST).
		expect(dublinToday(new Date("2026-10-09T23:30:00Z"))).toBe("2026-10-10");
	});
});

describe("rescheduleWarning", () => {
	it("counts the people emailed", () => {
		expect(rescheduleWarning(3)).toBe(
			"This emails 3 people “Workshop rescheduled”.",
		);
		expect(rescheduleWarning(1)).toBe(
			"This emails 1 person “Workshop rescheduled”.",
		);
		expect(rescheduleWarning(0)).toMatch(/nobody is emailed/);
	});
});
