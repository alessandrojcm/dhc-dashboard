import { describe, expect, it } from "vitest";
import { announcementProblem } from "./problem";

describe("announcementProblem", () => {
	it("reads the thrown problem body Phoenix renders", () => {
		const problem = announcementProblem({
			errors: {
				detail: "postTime: the first send instant has elapsed",
				fields: { postTime: ["the first send instant has elapsed"] },
			},
		});
		expect(problem?.detail).toMatch(/elapsed/);
		expect(problem?.fieldMessages).toEqual([
			{ field: "postTime", messages: ["the first send instant has elapsed"] },
		]);
	});

	it("unwraps the ky client error body", () => {
		const problem = announcementProblem({
			data: { errors: { detail: "Insufficient role", code: "forbidden" } },
		});
		expect(problem?.detail).toBe("Insufficient role");
		expect(problem?.code).toBe("forbidden");
		expect(problem?.fieldMessages).toEqual([]);
	});

	it("returns nothing for values that are not problem details", () => {
		expect(
			announcementProblem(new TypeError("Failed to fetch")),
		).toBeUndefined();
		expect(announcementProblem(undefined)).toBeUndefined();
	});
});
