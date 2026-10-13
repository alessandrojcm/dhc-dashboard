import * as v from "valibot";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
	BaseWorkshopSchema,
	startsDublinToday,
} from "#lib/schemas/workshop.js";

// 00:30 on Wednesday 15 July 2026 in Irish Summer Time, when the UTC date is
// still Tuesday 14 July.
const HALF_PAST_MIDNIGHT_IST = new Date("2026-07-14T23:30:00Z");

describe("startsDublinToday", () => {
	it("judges the start on Dublin's day, not the UTC one", () => {
		// 10:00 Dublin on Wednesday 15 July: today in Dublin.
		expect(
			startsDublinToday(
				new Date("2026-07-15T09:00:00Z"),
				HALF_PAST_MIDNIGHT_IST,
			),
		).toBe(true);
		// 18:00 Dublin on Tuesday 14 July: the UTC today, but yesterday in Dublin.
		expect(
			startsDublinToday(
				new Date("2026-07-14T17:00:00Z"),
				HALF_PAST_MIDNIGHT_IST,
			),
		).toBe(false);
	});

	it("reads a start just after Dublin midnight as that Dublin day", () => {
		// 00:15 IST on 16 July is 23:15 UTC on 15 July.
		expect(
			startsDublinToday(
				new Date("2026-07-15T23:15:00Z"),
				new Date("2026-07-16T08:00:00Z"),
			),
		).toBe(true);
	});
});

describe("BaseWorkshopSchema's today check", () => {
	beforeEach(() => {
		vi.useFakeTimers({ toFake: ["Date"] });
		vi.setSystemTime(HALF_PAST_MIDNIGHT_IST);
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	const workshop = (start: string) => ({
		title: "Longsword basics",
		location: "Main hall",
		workshop_date: new Date(start),
		workshop_end_date: new Date(new Date(start).getTime() + 2 * 3_600_000),
		max_capacity: 12,
		price_member: 10,
		refund_deadline_days: null,
	});

	it("refuses a workshop on Dublin's today at 00:30 summer time", () => {
		const result = v.safeParse(
			BaseWorkshopSchema,
			workshop("2026-07-15T17:30:00Z"),
		);
		expect(result.success).toBe(false);
		expect(result.issues?.[0]?.message).toBe(
			"Workshop cannot be scheduled for today",
		);
	});

	it("accepts a workshop on the UTC today that is already yesterday in Dublin", () => {
		expect(
			v.safeParse(BaseWorkshopSchema, workshop("2026-07-14T20:00:00Z")).success,
		).toBe(true);
	});
});
