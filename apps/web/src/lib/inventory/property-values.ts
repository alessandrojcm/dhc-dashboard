/**
 * An Item's property values on the quartermaster pages (ALE-416): the one
 * draft-map shape the create, edit and change-category forms hold, its
 * hidden-field encoding, the dirty comparison, and how a stored value reads
 * in copy.
 *
 * The draft is the request's `values` map: definition id → the raw value
 * (option id, text, decimal string or boolean), `null` for a cleared one.
 * It travels to the remote form as JSON in one hidden input, which the form
 * schema in `#lib/schemas/inventoryItem.js` decodes and validates.
 */
import {
	type InventoryOperatorItem,
	type InventoryOperatorItemValue,
	type InventoryOperatorItemValues,
	type InventoryPropertyDefinition,
} from "@dhc/api-client";
import * as v from "valibot";

export type PropertyDraft = InventoryOperatorItemValues;

// The generated `vInventoryOperatorItemValues` is an empty object schema
// (OpenAPI `additionalProperties`), which would strip every value.
const draftSchema = v.record(
	v.string(),
	v.nullable(v.union([v.string(), v.boolean(), v.number()])),
);

/** The draft an item's stored values start from. */
export function draftFromItem(
	item: Pick<InventoryOperatorItem, "values">,
): PropertyDraft {
	return Object.fromEntries(
		item.values.map((value) => [value.definitionId, storedValue(value)]),
	);
}

function storedValue(value: InventoryOperatorItemValue) {
	switch (value.valueType) {
		case "text":
			return value.text;
		case "decimal":
			return value.decimal;
		case "boolean":
			return value.boolean;
		case "single_select":
			return value.optionId;
	}
}

/** The hidden input's value. */
export function encodePropertyDraft(draft: PropertyDraft): string {
	return JSON.stringify(draft);
}

/** The hidden input read back; `undefined` when it is not a draft. */
export function decodePropertyDraft(
	encoded: string,
): PropertyDraft | undefined {
	let parsed: unknown;
	try {
		parsed = JSON.parse(encoded);
	} catch {
		return undefined;
	}
	// A record schema reads an array as an object keyed by index.
	if (Array.isArray(parsed)) return undefined;
	const draft = v.safeParse(draftSchema, parsed);
	return draft.success ? draft.output : undefined;
}

/**
 * Whether two drafts carry the same values. Key order does not matter, and a
 * cleared (`null`) value counts the same as one that was never set.
 */
export function sameDraft(a: PropertyDraft, b: PropertyDraft): boolean {
	const setA = setEntries(a);
	const setB = setEntries(b);
	return (
		setA.length === setB.length &&
		setA.every(([key, value]) => Object.is(b[key], value))
	);
}

function setEntries(draft: PropertyDraft) {
	return Object.entries(draft).filter(
		([, value]) => value !== null && value !== undefined,
	);
}

type DraftDefinition = Pick<InventoryPropertyDefinition, "id" | "valueType">;

/** A draft value as its control's string: `""` when unset. */
export function draftInput(draft: PropertyDraft, definitionId: string): string {
	return String(draft[definitionId] ?? "");
}

/**
 * The draft with one control's input applied: a boolean choice (`"true"` /
 * `"false"`) becomes a boolean, an emptied control clears the value.
 */
export function withDraftInput(
	draft: PropertyDraft,
	definition: DraftDefinition,
	input: string,
): PropertyDraft {
	const next =
		input === ""
			? null
			: definition.valueType === "boolean"
				? input === "true"
				: input;
	return { ...draft, [definition.id]: next };
}

/** The two choices of a boolean property, as the select offers them. */
export const BOOLEAN_CHOICES = [
	{ value: "true", label: "Yes" },
	{ value: "false", label: "No" },
] as const;

/** A stored value as copy, or `null` when it is not set. */
export function formatPropertyValue(
	value: InventoryOperatorItemValue,
): string | null {
	switch (value.valueType) {
		case "text":
			return value.text;
		case "decimal":
			return value.decimal === null ? null : formatDecimal(value.decimal);
		case "boolean":
			return value.boolean === null ? null : value.boolean ? "Yes" : "No";
		case "single_select":
			return value.optionLabel;
	}
}

/**
 * Phoenix sends decimals as strings to keep their precision; trailing zeros
 * are dropped on the string, never by parsing it into a float.
 */
function formatDecimal(decimal: string): string {
	if (!/^-?\d+\.\d+$/.test(decimal)) return decimal;
	return decimal.replace(/0+$/, "").replace(/\.$/, "");
}

/** An item's set values for a list row: `Size: Medium · Padded: Yes`. */
export function formatPropertyValues(
	values: readonly InventoryOperatorItemValue[],
): string {
	return values
		.flatMap((value) => {
			const formatted = formatPropertyValue(value);
			return formatted === null
				? []
				: [`${value.definitionLabel}: ${formatted}`];
		})
		.join(" · ");
}
