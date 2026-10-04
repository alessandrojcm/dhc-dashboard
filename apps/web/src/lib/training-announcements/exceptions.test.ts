import { describe, expect, it } from "vitest";
import {
	cappedExceptions,
	EXCEPTION_LIST_LIMIT,
	exceptionRangeLabel,
	hasDraftErrors,
	newOverrideDraft,
	newSuppressionDraft,
	nextResolvedTitle,
	overrideSummary,
	validateOverrideDraft,
	validateSuppressionDraft,
} from "./exceptions";

describe("exceptionRangeLabel", () => {
	it("reads a single date as the date itself", () => {
		expect(exceptionRangeLabel("2026-10-08", "2026-10-08")).toBe(
			"Thursday 8 October 2026",
		);
	});

	it("reads a range with an arrow between the two dates", () => {
		expect(exceptionRangeLabel("2026-10-08", "2026-10-22")).toContain("→");
	});
});

describe("overrideSummary", () => {
	it("names which copy the override replaces", () => {
		expect(overrideSummary({ title: "Special", message: null })).toBe(
			"Replaces the title",
		);
		expect(overrideSummary({ title: null, message: "New words" })).toBe(
			"Replaces the message",
		);
		expect(overrideSummary({ title: "Special", message: "New words" })).toBe(
			"Replaces the title and message",
		);
	});
});

describe("cappedExceptions", () => {
	it("shows every row when the list fits the cap", () => {
		const rows = [1, 2, 3];
		expect(cappedExceptions(rows)).toEqual({ visible: [1, 2, 3], hidden: 0 });
	});

	it("truncates to the cap and counts the remainder", () => {
		const rows = Array.from({ length: EXCEPTION_LIST_LIMIT + 3 }, (_, i) => i);
		const { visible, hidden } = cappedExceptions(rows);
		expect(visible).toHaveLength(EXCEPTION_LIST_LIMIT);
		expect(hidden).toBe(3);
	});
});

describe("nextResolvedTitle", () => {
	it("reads the thread name Phoenix computed, not the template", () => {
		expect(
			nextResolvedTitle([
				{
					threadName: "Roll call Thursday 8 October 2026",
				},
			]),
		).toBe("Roll call Thursday 8 October 2026");
	});

	it("is undefined without an upcoming occurrence", () => {
		expect(nextResolvedTitle(undefined)).toBeUndefined();
		expect(nextResolvedTitle([])).toBeUndefined();
	});
});

describe("drafts", () => {
	it("starts a suppression on today as a single date", () => {
		expect(newSuppressionDraft("2026-10-01")).toEqual({
			fromDate: "2026-10-01",
			toDate: "2026-10-01",
		});
	});

	it("starts an override pre-filled for a chosen date", () => {
		expect(newOverrideDraft("2026-10-01", "2026-10-08").fromDate).toBe(
			"2026-10-08",
		);
	});

	it("rejects a range that ends before it starts", () => {
		const errors = validateSuppressionDraft({
			fromDate: "2026-10-09",
			toDate: "2026-10-08",
		});
		expect(errors.toDate).toMatch(/ends before/);
		expect(hasDraftErrors(errors)).toBe(true);
	});

	it("requires an override to replace something", () => {
		const errors = validateOverrideDraft({
			fromDate: "2026-10-08",
			toDate: "2026-10-08",
			title: "  ",
			message: "",
		});
		expect(errors.title).toMatch(/title, the message, or both/);
	});
});
