import { describe, expect, it } from "vitest";
import {
	datesSetWindow,
	RETENTION_DAYS,
	retentionHorizon,
	windowAllowed,
} from "./window";

describe("retentionHorizon", () => {
	it("keeps 400 Dublin dates of history, like the Phoenix pruner", () => {
		// Mirrors `Dhc.TrainingAnnouncements.retention_horizon/0`: dates
		// strictly before it expire, so the calendar may ask for it but never
		// earlier.
		expect(RETENTION_DAYS).toBe(400);
		expect(retentionHorizon("2026-10-01")).toBe("2025-08-27");
	});

	it("crosses month and leap-day boundaries", () => {
		expect(retentionHorizon("2026-03-01")).toBe("2025-01-25");
		expect(retentionHorizon("2024-03-01")).toBe("2023-01-26");
	});
});

describe("datesSetWindow", () => {
	it("treats the calendar range end as exclusive", () => {
		// event-calendar's `datesSet` hands over the rendered grid with an
		// exclusive end, while `window` wants both bounds inclusive.
		expect(
			datesSetWindow("2026-09-28T00:00:00", "2026-11-09T00:00:00"),
		).toEqual({ from: "2026-09-28", to: "2026-11-08" });
	});

	it("accepts Date objects from the calendar callback", () => {
		expect(
			datesSetWindow(new Date(2026, 8, 28), new Date(2026, 10, 9)),
		).toEqual({ from: "2026-09-28", to: "2026-11-08" });
	});

	it("keeps a single week inside the 62-day window", () => {
		const week = datesSetWindow("2026-10-05T00:00:00", "2026-10-12T00:00:00");
		expect(week).toEqual({ from: "2026-10-05", to: "2026-10-11" });
	});
});

describe("windowAllowed", () => {
	it("refuses a range starting before the horizon", () => {
		expect(windowAllowed("2025-08-26", "2025-08-27")).toBe(false);
	});

	it("allows a range starting exactly on the horizon", () => {
		expect(windowAllowed("2025-08-27", "2025-08-27")).toBe(true);
	});
});
