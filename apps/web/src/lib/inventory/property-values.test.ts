import type { InventoryOperatorItemValue } from "@dhc/api-client";
import { describe, expect, it } from "vitest";
import {
	decodePropertyDraft,
	draftFromItem,
	draftInput,
	encodePropertyDraft,
	formatPropertyValue,
	formatPropertyValues,
	sameDraft,
	withDraftInput,
} from "./property-values";

function value(
	overrides: Partial<InventoryOperatorItemValue> &
		Pick<InventoryOperatorItemValue, "definitionId" | "valueType">,
): InventoryOperatorItemValue {
	return {
		definitionLabel: "Property",
		identifyingPosition: null,
		text: null,
		decimal: null,
		boolean: null,
		optionId: null,
		optionLabel: null,
		...overrides,
	};
}

const size = value({
	definitionId: "def-size",
	definitionLabel: "Size",
	valueType: "single_select",
	optionId: "opt-medium",
	optionLabel: "Medium",
});
const colour = value({
	definitionId: "def-colour",
	definitionLabel: "Colour",
	valueType: "text",
	text: "Black",
});
const weight = value({
	definitionId: "def-weight",
	definitionLabel: "Weight",
	valueType: "decimal",
	decimal: "1.50",
});
const padded = value({
	definitionId: "def-padded",
	definitionLabel: "Padded",
	valueType: "boolean",
	boolean: false,
});

describe("draftFromItem", () => {
	it("keys each stored value by its definition, as the request carries it", () => {
		expect(draftFromItem({ values: [size, colour, weight, padded] })).toEqual({
			"def-size": "opt-medium",
			"def-colour": "Black",
			"def-weight": "1.50",
			"def-padded": false,
		});
	});

	it("is empty for an item with no values", () => {
		expect(draftFromItem({ values: [] })).toEqual({});
	});
});

describe("hidden-field encoding", () => {
	it("round-trips a draft through the hidden input", () => {
		const draft = { "def-size": "opt-medium", "def-padded": true, x: null };
		expect(decodePropertyDraft(encodePropertyDraft(draft))).toEqual(draft);
	});

	it("decodes something that is not a draft as undefined", () => {
		expect(decodePropertyDraft("{not json")).toBeUndefined();
		expect(decodePropertyDraft("[1, 2]")).toBeUndefined();
		expect(decodePropertyDraft('{"a": {"b": 1}}')).toBeUndefined();
	});
});

describe("sameDraft", () => {
	it("ignores key order", () => {
		expect(sameDraft({ a: "1", b: true }, { b: true, a: "1" })).toBe(true);
	});

	it("treats a cleared value as the value never having been set", () => {
		expect(sameDraft({ a: "1", b: null }, { a: "1" })).toBe(true);
	});

	it("sees a changed, added or removed value", () => {
		expect(sameDraft({ a: "1" }, { a: "2" })).toBe(false);
		expect(sameDraft({ a: "1" }, { a: "1", b: false })).toBe(false);
		expect(sameDraft({ a: "1", b: false }, { a: "1", b: null })).toBe(false);
	});

	it("tells a boolean from its text", () => {
		expect(sameDraft({ a: true }, { a: "true" })).toBe(false);
	});
});

describe("draft inputs", () => {
	const booleanDefinition = { id: "def-padded", valueType: "boolean" } as const;
	const textDefinition = { id: "def-colour", valueType: "text" } as const;

	it("reads a value as the control's string", () => {
		expect(draftInput({ "def-padded": false }, "def-padded")).toBe("false");
		expect(draftInput({ "def-colour": "Black" }, "def-colour")).toBe("Black");
		expect(draftInput({}, "def-colour")).toBe("");
	});

	it("writes a boolean choice as a boolean", () => {
		expect(withDraftInput({}, booleanDefinition, "true")).toEqual({
			"def-padded": true,
		});
		expect(withDraftInput({}, booleanDefinition, "false")).toEqual({
			"def-padded": false,
		});
	});

	it("clears a value when the control is emptied", () => {
		expect(
			withDraftInput({ "def-colour": "Black" }, textDefinition, ""),
		).toEqual({ "def-colour": null });
		expect(
			withDraftInput({ "def-padded": true }, booleanDefinition, ""),
		).toEqual({ "def-padded": null });
	});

	it("leaves the draft it was given untouched", () => {
		const draft = { "def-colour": "Black" };
		withDraftInput(draft, textDefinition, "Red");
		expect(draft).toEqual({ "def-colour": "Black" });
	});
});

describe("formatPropertyValue", () => {
	it("says Yes or No for a boolean", () => {
		expect(formatPropertyValue({ ...padded, boolean: true })).toBe("Yes");
		expect(formatPropertyValue(padded)).toBe("No");
	});

	it("shows an option by its label, not its id", () => {
		expect(formatPropertyValue(size)).toBe("Medium");
	});

	it("drops trailing zeros from a decimal without rounding it", () => {
		expect(formatPropertyValue(weight)).toBe("1.5");
		expect(formatPropertyValue({ ...weight, decimal: "40.0" })).toBe("40");
		expect(formatPropertyValue({ ...weight, decimal: "120" })).toBe("120");
		expect(
			formatPropertyValue({ ...weight, decimal: "0.30000000000000004" }),
		).toBe("0.30000000000000004");
	});

	it("is null for a value that is not set", () => {
		expect(formatPropertyValue({ ...padded, boolean: null })).toBeNull();
		expect(formatPropertyValue({ ...colour, text: null })).toBeNull();
	});
});

describe("formatPropertyValues", () => {
	it("joins labelled values for a list row, skipping unset ones", () => {
		expect(
			formatPropertyValues([
				size,
				{ ...colour, text: null },
				weight,
				{ ...padded, boolean: true },
			]),
		).toBe("Size: Medium · Weight: 1.5 · Padded: Yes");
	});
});
