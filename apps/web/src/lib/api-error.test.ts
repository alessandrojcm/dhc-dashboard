import { describe, expect, it } from "vitest";
import { apiErrorDetail, apiErrorMessage, apiProblem } from "#lib/api-error.js";

describe("apiProblem", () => {
	it("reads detail, code and fields from the plain problem body", () => {
		expect(
			apiProblem({
				errors: {
					detail: "postTime: the first send instant has elapsed",
					code: "invalid_schedule",
					fields: { postTime: ["the first send instant has elapsed"] },
				},
			}),
		).toEqual({
			detail: "postTime: the first send instant has elapsed",
			code: "invalid_schedule",
			fields: [
				{ field: "postTime", messages: ["the first send instant has elapsed"] },
			],
		});
	});

	it("unwraps the ky client error body", () => {
		expect(
			apiProblem({
				data: {
					errors: { detail: "Item unavailable", code: "item_unavailable" },
				},
			}),
		).toEqual({
			detail: "Item unavailable",
			code: "item_unavailable",
			fields: [],
		});
	});

	it("leaves code undefined and fields empty when Phoenix omits them", () => {
		const problem = apiProblem({ errors: { detail: "Not found" } });
		expect(problem).toEqual({
			detail: "Not found",
			code: undefined,
			fields: [],
		});
	});

	it("keeps dotted field keys as one public field name", () => {
		const definitionId = "6f1c2a9e-1d0b-4c33-9b1f-3b5d2a7c8e10";
		const problem = apiProblem({
			data: {
				errors: {
					detail: `values.${definitionId}: required`,
					code: "invalid_property_values",
					fields: {
						[`values.${definitionId}`]: ["required"],
						name: ["can't be blank", "is too short"],
					},
				},
			},
		});
		expect(problem?.fields).toEqual([
			{ field: `values.${definitionId}`, messages: ["required"] },
			{ field: "name", messages: ["can't be blank", "is too short"] },
		]);
	});

	it("keeps the detail when code or fields are malformed", () => {
		const problem = apiProblem({
			errors: { detail: "Invalid request", code: 422, fields: "nope" },
		});
		expect(problem).toEqual({
			detail: "Invalid request",
			code: undefined,
			fields: [],
		});
	});

	it("returns nothing for values that are not problem details", () => {
		expect(apiProblem(new TypeError("Failed to fetch"))).toBeUndefined();
		expect(apiProblem(undefined)).toBeUndefined();
		expect(apiProblem(null)).toBeUndefined();
		expect(apiProblem("boom")).toBeUndefined();
		expect(apiProblem({ message: "boom" })).toBeUndefined();
		expect(apiProblem({ errors: "boom" })).toBeUndefined();
		expect(apiProblem({ data: { message: "boom" } })).toBeUndefined();
	});
});

describe("apiErrorDetail / apiErrorMessage", () => {
	it("reads the detail from either shape", () => {
		expect(apiErrorDetail({ errors: { detail: "Plain" } })).toBe("Plain");
		expect(apiErrorDetail({ data: { errors: { detail: "Ky" } } })).toBe("Ky");
	});

	it("falls back when there is no detail", () => {
		expect(apiErrorDetail(new Error("x"))).toBeUndefined();
		expect(apiErrorMessage(new Error("x"), "Fallback")).toBe("Fallback");
		expect(apiErrorMessage({ errors: {} }, "Fallback")).toBe("Fallback");
		expect(apiErrorMessage({ errors: { detail: "Real" } }, "Fallback")).toBe(
			"Real",
		);
	});
});
