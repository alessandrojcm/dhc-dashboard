import type { TrainingAnnouncement } from "@dhc/api-client";
import { describe, expect, it } from "vitest";
import { applyLifecycle, listIncludesRetired, withoutRow } from "./optimistic";

function row(id: string, overrides: Partial<TrainingAnnouncement> = {}) {
	return {
		id,
		kind: "roll_call",
		weekday: 4,
		oneOffDate: null,
		postTime: "10:00:00",
		title: "Roll call {{date}}",
		message: "Who is coming?",
		mentionEveryone: true,
		enabled: true,
		retired: false,
		firstAttemptedAt: null,
		createdAt: "2026-09-01T10:00:00Z",
		updatedAt: "2026-09-01T10:00:00Z",
		...overrides,
	} satisfies TrainingAnnouncement;
}

const rows = [row("a"), row("b")];

describe("applyLifecycle", () => {
	it("pauses and resumes only the targeted row", () => {
		const paused = applyLifecycle(rows, "a", "disable", false);
		expect(paused.map((r) => r.enabled)).toEqual([false, true]);
		expect(
			applyLifecycle(paused, "a", "enable", false).map((r) => r.enabled),
		).toEqual([true, true]);
	});

	it("drops a retired row from a list that excludes retired", () => {
		expect(applyLifecycle(rows, "a", "retire", false).map((r) => r.id)).toEqual(
			["b"],
		);
	});

	it("keeps a retired row, marked retired, in a list that includes retired", () => {
		const retired = applyLifecycle(rows, "a", "retire", true);
		expect(retired.map((r) => [r.id, r.retired])).toEqual([
			["a", true],
			["b", false],
		]);
	});

	it("drops a deleted row from every list", () => {
		expect(applyLifecycle(rows, "b", "delete", true).map((r) => r.id)).toEqual([
			"a",
		]);
	});

	it("does not mutate the cached rows", () => {
		applyLifecycle(rows, "a", "disable", false);
		expect(rows[0]?.enabled).toBe(true);
	});
});

describe("withoutRow", () => {
	it("removes only the matching id", () => {
		expect(withoutRow([{ id: "x" }, { id: "y" }], "x")).toEqual([{ id: "y" }]);
	});
});

describe("listIncludesRetired", () => {
	it("reads includeRetired from the generated key's query", () => {
		expect(
			listIncludesRetired([
				{ _id: "trainingAnnouncementsList", query: { includeRetired: true } },
			]),
		).toBe(true);
		expect(
			listIncludesRetired([
				{ _id: "trainingAnnouncementsList", query: { includeRetired: false } },
			]),
		).toBe(false);
	});

	it("treats a key without a query as the default, which excludes retired", () => {
		expect(listIncludesRetired([{ _id: "trainingAnnouncementsList" }])).toBe(
			false,
		);
		expect(listIncludesRetired([])).toBe(false);
	});
});
