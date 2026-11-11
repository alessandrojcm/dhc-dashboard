import { describe, expect, it } from "vitest";
import {
	destinationBody,
	destinationLines,
	destinationValues,
	directionsHref,
} from "#lib/destinations.js";

describe("destinationLines", () => {
	it("lists the name and address in that order", () => {
		expect(
			destinationLines({
				destinationName: "National Basketball Arena",
				destinationAddress: "Tymon Park, Dublin 6w",
			}),
		).toEqual(["National Basketball Arena", "Tymon Park, Dublin 6w"]);
	});

	it("shows whichever half exists alone", () => {
		expect(destinationLines({ destinationName: "Arena" })).toEqual(["Arena"]);
		expect(destinationLines({ destinationAddress: "Dublin 6w" })).toEqual([
			"Dublin 6w",
		]);
	});

	it("trims whitespace and treats blank entries as absent", () => {
		expect(
			destinationLines({
				destinationName: "  Arena  ",
				destinationAddress: "   ",
			}),
		).toEqual(["Arena"]);
	});

	it("is empty for legacy rows with only the label", () => {
		expect(destinationLines({})).toEqual([]);
		expect(
			destinationLines({
				destinationName: null,
				destinationAddress: null,
				directionsUrl: null,
			}),
		).toEqual([]);
	});
});

describe("directionsHref", () => {
	it("prefers the validated manual Maps link", () => {
		expect(
			directionsHref({
				destinationName: "Arena",
				destinationAddress: "Dublin 6w",
				directionsUrl: "https://maps.app.goo.gl/AbCdEf",
			}),
		).toBe("https://maps.app.goo.gl/AbCdEf");
	});

	it("builds a Maps search from the destination facts when there is no link", () => {
		expect(
			directionsHref({
				destinationName: "National Basketball Arena",
				destinationAddress: "Tymon Park, Dublin 6w",
			}),
		).toBe(
			"https://www.google.com/maps/search/?api=1&query=" +
				encodeURIComponent("National Basketball Arena, Tymon Park, Dublin 6w"),
		);
	});

	it("a link alone is still a usable destination", () => {
		expect(directionsHref({ directionsUrl: "https://goo.gl/maps/X" })).toBe(
			"https://goo.gl/maps/X",
		);
	});

	it("returns undefined for legacy label-only rows", () => {
		expect(directionsHref({})).toBeUndefined();
	});
});

describe("destinationBody", () => {
	it("sends every field, an emptied control as null so it clears", () => {
		expect(
			destinationBody({
				destination_name: "  Arena ",
				destination_address: "",
				directions_url: "   ",
				destination_place_id: "",
			}),
		).toEqual({
			destinationName: "Arena",
			destinationAddress: null,
			directionsUrl: null,
			destinationPlaceId: null,
		});
	});

	it("sends a selected place's ID beside the staff text, and no Google text (ALE-442)", () => {
		expect(
			destinationBody({
				destination_name: "Our hall",
				destination_address: "",
				directions_url: "",
				destination_place_id: "place_hall",
			}),
		).toEqual({
			destinationName: "Our hall",
			destinationAddress: null,
			directionsUrl: null,
			destinationPlaceId: "place_hall",
		});
	});
});

describe("selected Google places (ALE-442)", () => {
	const selected = {
		destinationName: "Our hall",
		destinationAddress: "1 Example Street, Dublin 8",
		directionsUrl: null,
		destinationProvider: "google" as const,
		destinationPlaceId: "place_hall",
	};

	it("links directions to the place by its Place ID, named by the staff text", () => {
		expect(directionsHref(selected, "Club hall")).toBe(
			"https://www.google.com/maps/dir/?api=1&destination=Our%20hall%2C%201%20Example%20Street%2C%20Dublin%208&destination_place_id=place_hall",
		);
	});

	it("names the place by the label when there is no staff text", () => {
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

	it("prefills the hidden Place ID control only for a selected place", () => {
		expect(destinationValues(selected)).toMatchObject({
			destination_name: "Our hall",
			destination_place_id: "place_hall",
		});
		expect(
			destinationValues({ ...selected, destinationProvider: null }),
		).toMatchObject({ destination_place_id: "" });
	});
});

describe("destinationValues", () => {
	it("prefills the controls from a saved destination, legacy rows empty", () => {
		expect(
			destinationValues({
				destinationName: "Arena",
				destinationAddress: null,
				directionsUrl: "https://maps.app.goo.gl/AbCdEf",
			}),
		).toEqual({
			destination_name: "Arena",
			destination_address: "",
			directions_url: "https://maps.app.goo.gl/AbCdEf",
			destination_place_id: "",
		});
		expect(destinationValues({})).toEqual({
			destination_name: "",
			destination_address: "",
			directions_url: "",
			destination_place_id: "",
		});
	});
});
