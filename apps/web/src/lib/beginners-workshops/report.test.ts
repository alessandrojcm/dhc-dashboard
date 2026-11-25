import { describe, expect, it } from "vitest";
import {
	afterAttendingDetail,
	attendanceDetail,
	carriedFeesNote,
	contactedDetail,
	countWithRate,
	exitsAfterPayingDetail,
	exitsBeforePayingDetail,
	formatDays,
	formatFigure,
	formatRate,
	groupDetail,
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
		).toBe("€35.00 originally paid · 1 missing the original payment record");
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
		expect(groupLabel(group)).toBe("Offer round 2");
		expect(
			groupLabel({
				...group,
				kind: "fast_track",
				number: null,
				windowEndsAt: null,
			}),
		).toBe("Added by staff");
	});

	it("details who was offered, who attended and who is still to join, skipping zeros", () => {
		expect(contactedDetail({ batch: 36, fastTrack: 0 })).toBe("36 automatic");
		expect(contactedDetail({ batch: 3, fastTrack: 5 })).toBe(
			"3 automatic · 5 added by staff",
		);
		expect(contactedDetail({ batch: 0, fastTrack: 0 })).toBe("");
		expect(attendanceDetail({ attended: 0, noShow: 1 })).toBe(
			"1 did not attend",
		);
		expect(
			afterAttendingDetail({ joined: 0, invitable: 0, invitedNotJoined: 0 }),
		).toBe("");
		expect(
			afterAttendingDetail({ joined: 2, invitable: 1, invitedNotJoined: 1 }),
		).toBe("1 ready to invite · 1 invited, not yet joined");
	});

	it("puts an offer round on one line, skipping empty outcomes", () => {
		expect(
			groupDetail({
				kind: "batch",
				number: 1,
				windowEndsAt: null,
				contacted: 5,
				paidInWindow: 3,
				paidLater: 0,
				declined: 0,
				unpaidAtCutoff: 2,
			}),
		).toBe("5 contacted · 3 paid within reply period · 2 unpaid at deadline");
	});

	it("details the exits, skipping empty kinds", () => {
		expect(
			exitsBeforePayingDetail({
				declined: 1,
				lapsed: 0,
				returned: 2,
				total: 3,
				rate: 0.3,
			}),
		).toBe("1 declined · 2 back on the waitlist");
		expect(
			exitsAfterPayingDetail({
				deferred: 0,
				cancelledRefunded: 1,
				withdrawn: 1,
				total: 2,
				rate: 0.2,
			}),
		).toBe("1 cancelled with refund requested · 1 withdrawn");
	});
});
