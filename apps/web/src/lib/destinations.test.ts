import { describe, expect, it } from "vitest";
import {
	destinationAttribution,
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
				destination_attributions: '[{"provider":"Ignored","providerUri":null}]',
			}),
		).toEqual({
			destinationName: "Arena",
			destinationAddress: null,
			directionsUrl: null,
			destinationPlaceId: null,
			destinationAttributions: [],
		});
	});

	it("sends a selected place with its credits, and drops malformed credits (ALE-442)", () => {
		const selected = {
			destination_name: "Synthetic Fencing Hall",
			destination_address: "1 Example Street",
			directions_url: "",
			destination_place_id: "place_hall",
		};
		expect(
			destinationBody({
				...selected,
				destination_attributions:
					'[{"provider":"Venue Guide","providerUri":"https://guide.test/"}]',
			}),
		).toMatchObject({
			destinationPlaceId: "place_hall",
			destinationAttributions: [
				{ provider: "Venue Guide", providerUri: "https://guide.test/" },
			],
		});
		expect(
			destinationBody({ ...selected, destination_attributions: "{not json" })
				.destinationAttributions,
		).toEqual([]);
		expect(
			destinationBody({
				...selected,
				destination_attributions: '[{"provider":""}]',
			}).destinationAttributions,
		).toEqual([]);
	});
});

describe("selected Google places (ALE-442)", () => {
	const selected = {
		destinationName: "Synthetic Fencing Hall",
		destinationAddress: "1 Example Street, Dublin 8",
		directionsUrl: null,
		destinationProvider: "google" as const,
		destinationPlaceId: "place_hall",
		destinationAttributions: [{ provider: "Venue Guide", providerUri: null }],
	};

	it("links directions to the selected place by its Place ID", () => {
		expect(directionsHref(selected)).toBe(
			"https://www.google.com/maps/dir/?api=1&destination=Synthetic%20Fencing%20Hall%2C%201%20Example%20Street%2C%20Dublin%208&destination_place_id=place_hall",
		);
	});

	it("attributes only Google-derived destinations", () => {
		expect(destinationAttribution(selected)).toEqual({
			credits: [{ provider: "Venue Guide", providerUri: null }],
		});
		expect(
			destinationAttribution({ ...selected, destinationProvider: null }),
		).toBeUndefined();
		expect(destinationAttribution({ destinationName: "Hall" })).toBeUndefined();
	});

	it("prefills the hidden selection controls only for a selected place", () => {
		expect(destinationValues(selected)).toMatchObject({
			destination_place_id: "place_hall",
			destination_attributions:
				'[{"provider":"Venue Guide","providerUri":null}]',
		});
		expect(
			destinationValues({ ...selected, destinationProvider: null }),
		).toMatchObject({ destination_place_id: "", destination_attributions: "" });
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
			destination_attributions: "",
		});
		expect(destinationValues({})).toEqual({
			destination_name: "",
			destination_address: "",
			directions_url: "",
			destination_place_id: "",
			destination_attributions: "",
		});
	});
});
