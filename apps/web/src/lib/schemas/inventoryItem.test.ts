import * as v from "valibot";
import { describe, expect, it } from "vitest";
import {
	archiveItemSchema,
	createItemSchema,
	deleteItemSchema,
	updateItemSchema,
} from "./inventoryItem";

const CATEGORY = "33333333-3333-4333-8333-333333333333";
const CONTAINER = "55555555-5555-4555-8555-555555555555";
const SIZE = "11111111-1111-4111-8111-111111111111";

describe("inventory Item form schemas", () => {
	it("sends a create as the request body, with blank notes as null", () => {
		expect(
			v.parse(createItemSchema, {
				categoryId: CATEGORY,
				containerId: CONTAINER,
				notes: "   ",
				values: JSON.stringify({ [SIZE]: "opt-medium" }),
			}),
		).toEqual({
			body: {
				categoryId: CATEGORY,
				containerId: CONTAINER,
				notes: null,
				values: { [SIZE]: "opt-medium" },
			},
		});
	});

	it("splits the addressed item from an update's body and trims its notes", () => {
		expect(
			v.parse(updateItemSchema, {
				slugOrId: "item-000001",
				notes: "  Sharpened ",
				values: "{}",
			}),
		).toEqual({
			slugOrId: "item-000001",
			body: { notes: "Sharpened", values: {} },
		});
	});

	it("refuses property values that are not a draft", () => {
		const result = v.safeParse(updateItemSchema, {
			slugOrId: "item-000001",
			notes: "",
			values: "[1]",
		});

		expect(result.success).toBe(false);
		expect(result.issues?.[0]?.message).toBe("Item properties are invalid");
	});

	it("sends an archive's blank note as null", () => {
		expect(
			v.parse(archiveItemSchema, { slugOrId: "item-000001", reason: " " }),
		).toEqual({ slugOrId: "item-000001", body: { reason: null } });
	});

	it("confirms a delete with a literal true", () => {
		expect(v.parse(deleteItemSchema, { slugOrId: "item-000001" })).toEqual({
			slugOrId: "item-000001",
			body: { confirm: true },
		});
	});
});
