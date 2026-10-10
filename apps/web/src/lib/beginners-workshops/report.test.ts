import { describe, expect, it } from "vitest";
import {
	carriedFeesNote,
	countWithRate,
	exitsAfterPayingDetail,
	exitsBeforePayingDetail,
	formatDays,
	formatFigure,
	formatRate,
	groupLabel,
} from "#lib/beginners-workshops/report.js";

describe("report wording", () => {
	it("says a rate as a percentage, and nothing when there is no rate", () => {
		expect(formatRate(0.5)).toBe("50%");
		expect(formatRate(2 / 9)).toBe("22%");
		expect(formatRate(null)).toBe("—");
	});

	it("says days and figures, and nothing when there is nothing to measure", () => {
		expect(formatDays(1)).toBe("1 day");
		expect(formatDays(274.5)).toBe("274.5 days");
		expect(formatDays(null)).toBe("—");
		expect(formatFigure(4)).toBe("4");
		expect(formatFigure(null)).toBe("—");
	});

	it("puts an exit count beside its rate", () => {
		expect(countWithRate(2, 2 / 9)).toBe("2 · 22%");
		expect(countWithRate(1, null)).toBe("1");
	});

	it("names unlinked Carried Fees under the total originally paid", () => {
		expect(
			carriedFeesNote({ count: 2, totalPaidCents: 3500, unlinked: 1 }),
		).toBe("€35.00 originally paid · 1 not linked to a payment yet");
		expect(
			carriedFeesNote({ count: 1, totalPaidCents: 4000, unlinked: 0 }),
		).toBe("€40.00 originally paid");
	});

	it("labels Batches and fast-tracks", () => {
		const group = {
			kind: "batch" as const,
			number: 2,
			windowEndsAt: "2026-10-27T22:59:59Z",
			contacted: 1,
			paidInWindow: 1,
			paidLater: 0,
			declined: 0,
			unpaidAtCutoff: 0,
		};
		expect(groupLabel(group)).toBe("Batch 2");
		expect(
			groupLabel({
				...group,
				kind: "fast_track",
				number: null,
				windowEndsAt: null,
			}),
		).toBe("Fast-tracks");
	});

	it("details the exits, skipping empty kinds", () => {
		expect(
			exitsBeforePayingDetail({
				declined: 1,
				lapsed: 0,
				returned: 2,
				withdrawn: 0,
				total: 3,
				rate: 0.3,
			}),
		).toBe("1 declined · 2 returned");
		expect(
			exitsAfterPayingDetail({
				deferred: 0,
				cancelledRefunded: 1,
				withdrawn: 1,
				total: 2,
				rate: 0.2,
			}),
		).toBe("1 refunded · 1 withdrawn");
	});
});
