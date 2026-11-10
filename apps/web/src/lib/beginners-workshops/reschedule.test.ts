import { describe, expect, it } from "vitest";
import {
	keptContactFrom,
	keptCutoff,
	rescheduleOperation,
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

describe("rescheduleWarning", () => {
	it("counts the people emailed", () => {
		expect(rescheduleWarning(3)).toBe(
			"This emails 3 people “Workshop rescheduled”.",
		);
		expect(rescheduleWarning(1)).toBe(
			"This emails 1 person “Workshop rescheduled”.",
		);
		expect(rescheduleWarning(0)).toBe(
			"No emails will be sent: nobody has an active workshop place.",
		);
	});

	it("never warns of emails for a destination-only change", () => {
		expect(rescheduleWarning(3, "destination")).toBe(
			"No emails will be sent: only the destination details change.",
		);
	});
});

describe("rescheduleOperation", () => {
	const current = {
		date: "2026-11-14",
		startTime: "18:30",
		endTime: "20:30",
		venue: "St. Andrew's Hall",
		destinationName: "Arena",
		destinationAddress: null,
		directionsUrl: null,
		destinationProvider: null,
		destinationPlaceId: null,
		destinationAttributions: [],
	};
	const unchanged = {
		date: "2026-11-14",
		startTime: "18:30",
		endTime: "20:30",
		venue: "St. Andrew's Hall",
		destination_name: "Arena",
		destination_address: "",
		directions_url: "",
		destination_place_id: "",
		destination_attributions: "",
	};

	it("is a destination-only change while the date, times and venue stay", () => {
		for (const edit of [
			{ destination_address: "Tymon Park, Dublin 6w" },
			{ destination_name: "" },
			{ directions_url: "https://maps.app.goo.gl/AbCdEf" },
		]) {
			expect(rescheduleOperation(current, { ...unchanged, ...edit })).toBe(
				"destination",
			);
		}
		// Surrounding whitespace and seconds are not a move.
		expect(
			rescheduleOperation(current, {
				...unchanged,
				startTime: "18:30:00",
				venue: "  St. Andrew's Hall ",
				destination_name: "Arena Two",
			}),
		).toBe("destination");
	});

	it("selecting, replacing or removing a Google place is a destination-only change (ALE-442)", () => {
		expect(
			rescheduleOperation(current, {
				...unchanged,
				destination_place_id: "place_hall",
			}),
		).toBe("destination");

		const selected = {
			...current,
			destinationProvider: "google" as const,
			destinationPlaceId: "place_hall",
		};
		const resubmitted = {
			...unchanged,
			destination_place_id: "place_hall",
			destination_attributions: "[]",
		};
		expect(rescheduleOperation(selected, resubmitted)).toBe("reschedule");
		expect(
			rescheduleOperation(selected, {
				...resubmitted,
				destination_place_id: "place_annex",
			}),
		).toBe("destination");
		expect(rescheduleOperation(selected, unchanged)).toBe("destination");
	});

	it("stays a reschedule when nothing changed, so Phoenix asks for a move", () => {
		expect(
			rescheduleOperation(current, {
				...unchanged,
				destination_name: " Arena ",
			}),
		).toBe("reschedule");
	});

	it("is a reschedule when any schedule value moves, destination or not", () => {
		for (const moved of [
			{ date: "2026-11-21" },
			{ startTime: "19:00" },
			{ endTime: "21:00" },
			{ venue: "The Hub", destination_name: "The Hub" },
		]) {
			expect(rescheduleOperation(current, { ...unchanged, ...moved })).toBe(
				"reschedule",
			);
		}
	});

	it("treats an explicit end on a legacy workshop with no end as a move", () => {
		expect(rescheduleOperation({ ...current, endTime: null }, unchanged)).toBe(
			"reschedule",
		);
	});
});
