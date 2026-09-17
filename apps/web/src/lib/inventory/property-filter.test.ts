import { describe, expect, it } from "vitest";
import { encodePropertyFilter, propertyFilterEntries } from "./property-filter";

describe("encodePropertyFilter", () => {
	it("joins definition/value pairs for the catalog property param", () => {
		expect(
			encodePropertyFilter([
				{ definitionId: "def-a", value: "Regenyei" },
				{ definitionId: "def-b", value: "true" },
			]),
		).toBe("def-a:Regenyei,def-b:true");
	});

	it("omits blank values and returns undefined when nothing remains", () => {
		expect(
			encodePropertyFilter([
				{ definitionId: "def-a", value: "  " },
				{ definitionId: "", value: "x" },
			]),
		).toBeUndefined();
	});
});

describe("propertyFilterEntries", () => {
	it("turns the UI record into encodeable pairs", () => {
		expect(propertyFilterEntries({ "def-a": "Medium", "def-b": "" })).toEqual([
			{ definitionId: "def-a", value: "Medium" },
			{ definitionId: "def-b", value: "" },
		]);
	});
});
