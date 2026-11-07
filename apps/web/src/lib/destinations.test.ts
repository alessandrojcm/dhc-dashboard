import { describe, expect, it } from "vitest";
import { destinationLines, directionsHref } from "#lib/destinations.js";

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
