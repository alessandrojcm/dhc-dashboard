import { describe, expect, it } from "vitest";
import {
	rescheduleFormPath,
	scheduleFormPath,
} from "#lib/server/beginners-workshops/form-paths.js";

describe("destination field paths (ALE-441)", () => {
	it("puts a scheduled date's destination refusal under the shared control", () => {
		expect(scheduleFormPath("workshops.1.directionsUrl")).toEqual([
			"directions_url",
		]);
		expect(scheduleFormPath("workshops.0.destinationName")).toEqual([
			"destination_name",
		]);
		// Per-date fields still land on that date's row.
		expect(scheduleFormPath("workshops.1.date")).toEqual([
			"workshops",
			1,
			"date",
		]);
	});

	it("puts a reschedule or destination-only refusal under the dialog's control", () => {
		expect(rescheduleFormPath("destinationAddress")).toEqual([
			"destination_address",
		]);
		expect(rescheduleFormPath("venue")).toEqual(["venue"]);
		expect(rescheduleFormPath("feeCents")).toBeUndefined();
	});

	it("puts a refused Google selection under the destination name (ALE-442)", () => {
		expect(scheduleFormPath("workshops.0.destinationPlaceId")).toEqual([
			"destination_name",
		]);
		expect(rescheduleFormPath("destinationAttributions")).toEqual([
			"destination_name",
		]);
	});
});
