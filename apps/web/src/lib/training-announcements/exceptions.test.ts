import { describe, expect, it } from "vitest";
import {
	cappedExceptions,
	EXCEPTION_LIST_LIMIT,
	exceptionRangeLabel,
	friendlyOverrideDetail,
	friendlyOverrideFieldMessage,
	hasDraftErrors,
	newOverrideDraft,
	newSuppressionDraft,
	nextResolvedTitle,
	OVERRIDE_OVERLAP_GUIDANCE,
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
					subject: "occurrence",
					threadName: "Roll call Thursday 8 October 2026",
				},
			]),
		).toBe("Roll call Thursday 8 October 2026");
	});

	it("names a holiday notice, which has no thread", () => {
		expect(nextResolvedTitle([{ subject: "holiday", threadName: null }])).toBe(
			"Holiday notice",
		);
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

	it("starts an override pre-filled with the current copy", () => {
		expect(
			newOverrideDraft("2026-10-01", "2026-10-08", {
				title: "Roll call {{date}}",
				message: "Who is coming?",
			}),
		).toEqual({
			fromDate: "2026-10-08",
			toDate: "2026-10-08",
			title: "Roll call {{date}}",
			message: "Who is coming?",
		});
	});

	it("starts an override with empty copy when there is nothing to pre-fill", () => {
		expect(newOverrideDraft("2026-10-01")).toEqual({
			fromDate: "2026-10-01",
			toDate: "2026-10-01",
			title: "",
			message: "",
		});
	});

	it("rejects a range that ends before it starts", () => {
		const errors = validateSuppressionDraft({
			fromDate: "2026-10-09",
			toDate: "2026-10-08",
		});
		expect(errors.toDate).toBe(
			"The last date must be on or after the first date.",
		);
		expect(hasDraftErrors(errors)).toBe(true);
	});

	it("requires an override to replace something", () => {
		const errors = validateOverrideDraft({
			fromDate: "2026-10-08",
			toDate: "2026-10-08",
			title: "  ",
			message: "",
		});
		expect(errors.title).toBe("Enter a title or message to save a change.");
	});
});

describe("overlap guidance", () => {
	it("rewords the overlap refusal as delete-first guidance", () => {
		expect(
			friendlyOverrideFieldMessage(
				"overlaps another override for this announcement",
			),
		).toBe(OVERRIDE_OVERLAP_GUIDANCE);
		expect(
			friendlyOverrideDetail(
				"fromDate: overlaps another override for this announcement",
			),
		).toBe(OVERRIDE_OVERLAP_GUIDANCE);
		expect(OVERRIDE_OVERLAP_GUIDANCE).toMatch(/Delete the existing/i);
	});

	it("leaves every other message untouched", () => {
		expect(friendlyOverrideFieldMessage("must be today or later")).toBe(
			"must be today or later",
		);
		expect(friendlyOverrideDetail(undefined)).toBeUndefined();
		expect(friendlyOverrideDetail("Something else went wrong")).toBe(
			"Something else went wrong",
		);
	});
});
