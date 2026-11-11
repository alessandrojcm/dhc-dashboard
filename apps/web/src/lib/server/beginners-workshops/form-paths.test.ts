import { describe, expect, it } from "vitest";
import {
	rescheduleFormPath,
	scheduleFormPath,
} from "#lib/server/beginners-workshops/form-paths.js";

describe("destination field paths (ALE-441)", () => {
	it("puts a scheduled date's destination refusal under the shared control", () => {
		expect(scheduleFormPath("workshops.1.destinationText")).toEqual([
			"destination_text",
		]);
		// Per-date fields still land on that date's row.
		expect(scheduleFormPath("workshops.1.date")).toEqual([
			"workshops",
			1,
			"date",
		]);
	});

	it("puts a reschedule or destination-only refusal under the dialog's control", () => {
		expect(rescheduleFormPath("destinationText")).toEqual(["destination_text"]);
		expect(rescheduleFormPath("venue")).toEqual(["venue"]);
		expect(rescheduleFormPath("feeCents")).toBeUndefined();
	});

	it("puts a refused Google selection on the selected place (ALE-442)", () => {
		expect(scheduleFormPath("workshops.0.destinationPlaceId")).toEqual([
			"destination_place_id",
		]);
		expect(rescheduleFormPath("destinationPlaceId")).toEqual([
			"destination_place_id",
		]);
		expect(rescheduleFormPath("destinationAttributions")).toBeUndefined();
	});
});
