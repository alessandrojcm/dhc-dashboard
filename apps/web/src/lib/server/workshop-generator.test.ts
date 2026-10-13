import * as v from "valibot";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
	coerceToCreateWorkshopSchema,
	LLMCreateWorkshopSchema,
	workshopGeneratorSystemPrompt,
	type WorkshopDraft,
} from "#lib/server/workshop-generator.js";

// 00:30 on Wednesday 14 October 2026 in Irish Summer Time, while the UTC
// clock still reads Tuesday 13 October.
const HALF_PAST_MIDNIGHT_IST = new Date("2026-10-13T23:30:00Z");

const draft = (overrides: Partial<WorkshopDraft> = {}): WorkshopDraft => ({
	title: "Longsword basics",
	description: "",
	location: "St Catherines Sport Centre",
	workshop_date: "2026-11-20",
	start_time: "14:00",
	end_time: "16:00",
	max_capacity: 12,
	price_member: 2000,
	price_non_member: 2500,
	is_public: true,
	refund_deadline_days: 3,
	announce_discord: false,
	announce_email: false,
	...overrides,
});

describe("workshopGeneratorSystemPrompt", () => {
	it("tells the model Dublin's today and time, not the UTC ones", () => {
		const prompt = workshopGeneratorSystemPrompt(HALF_PAST_MIDNIGHT_IST);
		expect(prompt).toContain(
			"Today in Dublin is Wednesday, 14 October 2026 (2026-10-14), and the time in Dublin is 00:30.",
		);
	});

	it("builds its examples from Dublin civil dates and wall-clock times", () => {
		const prompt = workshopGeneratorSystemPrompt(HALF_PAST_MIDNIGHT_IST);
		// Next Saturday, tomorrow and Saturday next week, all counted from
		// Dublin's Wednesday.
		expect(prompt).toContain(
			'"workshop_date":"2026-10-17","start_time":"14:00","end_time":"15:00"',
		);
		expect(prompt).toContain(
			'"workshop_date":"2026-10-15","start_time":"14:00","end_time":"15:00"',
		);
		expect(prompt).toContain(
			'"workshop_date":"2026-10-24","start_time":"10:00","end_time":"16:00"',
		);
		expect(prompt).not.toMatch(/\d{4}-\d{2}-\d{2}T/);
	});

	it("never offers today as next Saturday", () => {
		const prompt = workshopGeneratorSystemPrompt(
			new Date("2026-10-17T12:00:00Z"),
		);
		expect(prompt).toContain(
			'"workshop_date":"2026-10-24","start_time":"14:00"',
		);
		expect(prompt).not.toContain('"workshop_date":"2026-10-17"');
	});

	it("words the refusal for today plainly", () => {
		const prompt = workshopGeneratorSystemPrompt(HALF_PAST_MIDNIGHT_IST);
		expect(prompt).toContain("Workshop cannot be scheduled for today");
		expect(prompt).not.toContain("cannot today");
	});
});

describe("coerceToCreateWorkshopSchema", () => {
	beforeEach(() => {
		vi.useFakeTimers({ toFake: ["Date"] });
		vi.setSystemTime(HALF_PAST_MIDNIGHT_IST);
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it("reads the times on the Dublin clock in summer time", () => {
		const result = coerceToCreateWorkshopSchema(
			draft({ workshop_date: "2026-10-20" }),
		);
		expect(result.success).toBe(true);
		if (!result.success) return;
		expect(result.output.workshop_date.toISOString()).toBe(
			"2026-10-20T13:00:00.000Z",
		);
		expect(result.output.workshop_end_date.toISOString()).toBe(
			"2026-10-20T15:00:00.000Z",
		);
	});

	it("reads the times on the Dublin clock after the clocks go back", () => {
		const result = coerceToCreateWorkshopSchema(draft());
		expect(result.success).toBe(true);
		if (!result.success) return;
		expect(result.output.workshop_date.toISOString()).toBe(
			"2026-11-20T14:00:00.000Z",
		);
	});

	it("turns cents into the form's euros", () => {
		const result = coerceToCreateWorkshopSchema(draft());
		expect(result.success).toBe(true);
		if (!result.success) return;
		expect(result.output.price_member).toBe(20);
		expect(result.output.price_non_member).toBe(25);
	});

	it("survives the trip through the create page's URL", () => {
		const result = coerceToCreateWorkshopSchema(
			JSON.parse(
				decodeURIComponent(encodeURIComponent(JSON.stringify(draft()))),
			),
		);
		expect(result.success).toBe(true);
	});

	it.each([
		["an end before the start", { start_time: "15:00", end_time: "14:00" }],
		["an end at the start", { start_time: "14:00", end_time: "14:00" }],
		["an impossible time", { start_time: "25:00" }],
		["an impossible day", { workshop_date: "2026-02-30" }],
		["an instant instead of a date", { workshop_date: "2026-11-20T14:00:00Z" }],
		["a start on Dublin's today", { workshop_date: "2026-10-14" }],
	])("fails for %s", (_, overrides) => {
		expect(coerceToCreateWorkshopSchema(draft(overrides)).success).toBe(false);
	});
});
