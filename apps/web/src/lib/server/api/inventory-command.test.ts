import { isValidationError } from "@sveltejs/kit";
import { describe, expect, it } from "vitest";
import { inventoryCommand } from "#lib/server/api/inventory-command.js";

// Stands in for SvelteKit's remote-form `issue` builder: each field builds an
// issue on its own path, exactly as the real proxy does.
function fakeIssue<const Field extends string>(fields: readonly Field[]) {
	// SAFETY: the entries are built from exactly `fields`, one builder each.
	return Object.fromEntries(
		fields.map((field) => [
			field,
			(message: string) => ({ message, path: [field] }),
		]),
	) as Record<Field, (message: string) => { message: string; path: Field[] }>;
}

function rejection(errors: {
	detail?: string;
	code?: string;
	fields?: Record<string, string[]>;
}) {
	return Promise.resolve({ error: { errors } });
}

async function issuesOf(promise: Promise<unknown>) {
	try {
		await promise;
	} catch (cause) {
		if (isValidationError(cause)) return cause.issues;
		throw cause;
	}
	throw new Error("Expected the command to reject with invalid()");
}

describe("inventoryCommand", () => {
	it("passes a successful response's data through", async () => {
		const item = { id: "item-1", slug: "item-000001" };

		const result = await inventoryCommand(
			Promise.resolve({ data: { data: item } }),
			{
				fallback: "Could not create item",
				fields: ["notes"],
				issue: fakeIssue(["notes"]),
			},
		);

		expect(result).toEqual({ ok: true, data: item });
	});

	it("answers a rejection no form field can carry with its detail", async () => {
		const result = await inventoryCommand(
			rejection({
				detail:
					"required cannot be set until every active item has a valid value",
				code: "required_blocked",
				fields: { "items.4b1c": ["has no valid value"] },
			}),
			{
				fallback: "Could not update property",
				fields: ["label", "required"],
				issue: fakeIssue(["label", "required"]),
			},
		);

		expect(result).toEqual({
			ok: false,
			error: "required cannot be set until every active item has a valid value",
		});
	});

	it("falls back when the rejection is not a problem body", async () => {
		const result = await inventoryCommand(
			Promise.resolve({ error: new TypeError("fetch failed") }),
			{
				fallback: "Could not move item",
				fields: ["containerId"],
				issue: fakeIssue(["containerId"]),
			},
		);

		expect(result).toEqual({ ok: false, error: "Could not move item" });
	});

	it("puts a rejection naming a form field on that field", async () => {
		const issues = await issuesOf(
			inventoryCommand(
				rejection({
					detail: "name: has already been taken",
					fields: { name: ["has already been taken"] },
				}),
				{
					fallback: "Could not create category",
					fields: ["name", "description"],
					issue: fakeIssue(["name", "description"]),
				},
			),
		);

		expect(issues).toEqual([
			{ message: "has already been taken", path: ["name"] },
		]);
	});

	it("names each rejected property value on the values field", async () => {
		const labels = new Map([
			["def-blade", "Blade length"],
			["def-grip", "Grip"],
			["def-size", "Size"],
			["def-old", "Maker"],
		]);

		const issues = await issuesOf(
			inventoryCommand(
				rejection({
					detail: "One or more property values are invalid",
					code: "invalid_values",
					fields: {
						"values.def-blade": ["required"],
						"values.def-grip": ["type_mismatch"],
						"values.def-size": ["unknown_option"],
						"values.def-colour": ["retired_option"],
						"values.def-old": ["retired_definition"],
						"values.def-stray": ["unknown_definition"],
					},
				}),
				{
					fallback: "Could not create item",
					fields: ["notes", "values"],
					issue: fakeIssue(["notes", "values"]),
					propertyLabels: async () => labels,
				},
			),
		);

		expect(issues).toEqual([
			{ message: "Blade length is required", path: ["values"] },
			{ message: "Enter a valid value for Grip", path: ["values"] },
			{ message: "Choose one of the options for Size", path: ["values"] },
			{
				message: "The option chosen for a property has been retired",
				path: ["values"],
			},
			{
				message: "Maker has been retired and can no longer be set",
				path: ["values"],
			},
			{
				message: "A property does not belong to this category",
				path: ["values"],
			},
		]);
	});

	it("does not look up property names when no value was rejected", async () => {
		let lookedUp = false;

		await issuesOf(
			inventoryCommand(rejection({ fields: { notes: ["is too long"] } }), {
				fallback: "Could not update item",
				fields: ["notes", "values"],
				issue: fakeIssue(["notes", "values"]),
				propertyLabels: async () => {
					lookedUp = true;
					return new Map();
				},
			}),
		);

		expect(lookedUp).toBe(false);
	});
});
