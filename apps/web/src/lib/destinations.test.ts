import { describe, expect, it } from "vitest";
import {
	destinationBody,
	destinationLines,
	destinationValues,
	directionsHref,
} from "#lib/destinations.js";

describe("destinationLines", () => {
	it("shows the manual text as one line", () => {
		expect(
			destinationLines({
				destinationText: "National Basketball Arena, Tymon Park, Dublin 6w",
			}),
		).toEqual(["National Basketball Arena, Tymon Park, Dublin 6w"]);
	});

	it("trims whitespace and treats blank text as absent", () => {
		expect(destinationLines({ destinationText: "  Arena  " })).toEqual([
			"Arena",
		]);
		expect(destinationLines({ destinationText: "   " })).toEqual([]);
	});

	it("is empty for legacy rows and for a selected place (no Google text)", () => {
		expect(destinationLines({})).toEqual([]);
		expect(destinationLines({ destinationText: null })).toEqual([]);
		expect(
			destinationLines({
				destinationProvider: "google",
				destinationPlaceId: "place_hall",
			}),
		).toEqual([]);
	});
});

describe("directionsHref", () => {
	it("builds a Maps search for exactly the manual text", () => {
		expect(
			directionsHref(
				{ destinationText: "National Basketball Arena, Tymon Park, Dublin 6w" },
				"Club hall",
			),
		).toBe(
			"https://www.google.com/maps/search/?api=1&query=" +
				encodeURIComponent("National Basketball Arena, Tymon Park, Dublin 6w"),
		);
	});

	it("links directions to a selected place by its Place ID, named by the label", () => {
		expect(
			directionsHref(
				{ destinationProvider: "google", destinationPlaceId: "place hall" },
				"St. Andrew's Hall",
			),
		).toBe(
			"https://www.google.com/maps/dir/?api=1&destination=St.%20Andrew's%20Hall&destination_place_id=place%20hall",
		);
	});

	it("ignores a Place ID without the Google provider", () => {
		expect(
			directionsHref({ destinationPlaceId: "place_hall" }, "Club hall"),
		).toBeUndefined();
	});

	it("returns undefined for legacy label-only rows", () => {
		expect(directionsHref({}, "Club hall")).toBeUndefined();
	});
});

describe("destinationBody", () => {
	it("sends both fields, an emptied control as null so it clears", () => {
		expect(
			destinationBody({
				destination_text: "  Arena ",
				destination_place_id: "",
			}),
		).toEqual({ destinationText: "Arena", destinationPlaceId: null });
		expect(
			destinationBody({ destination_text: "   ", destination_place_id: "" }),
		).toEqual({ destinationText: null, destinationPlaceId: null });
	});

	it("sends only the Place ID for a selected place, never text (ALE-442)", () => {
		expect(
			destinationBody({
				destination_text: "Google's suggestion text",
				destination_place_id: "place_hall",
			}),
		).toEqual({ destinationText: null, destinationPlaceId: "place_hall" });
	});
});

describe("destinationValues", () => {
	it("prefills the manual text, legacy rows empty", () => {
		expect(destinationValues({ destinationText: "Arena" })).toEqual({
			destination_text: "Arena",
			destination_place_id: "",
		});
		expect(destinationValues({})).toEqual({
			destination_text: "",
			destination_place_id: "",
		});
	});

	it("prefills the Place ID only for a selected Google place", () => {
		expect(
			destinationValues({
				destinationProvider: "google",
				destinationPlaceId: "place_hall",
			}),
		).toEqual({ destination_text: "", destination_place_id: "place_hall" });
		expect(destinationValues({ destinationPlaceId: "place_hall" })).toEqual({
			destination_text: "",
			destination_place_id: "",
		});
	});
});
