import { describe, expect, it } from "vitest";
import type { TrainingAnnouncementKind } from "@dhc/api-client";
import {
	COPY_PRESETS,
	KIND_CHANNEL_LABELS,
	KIND_LABELS,
	MESSAGE_TOKENS,
	TITLE_TOKENS,
	WEEKDAY_NAMES,
	WEEKDAY_OPTIONS,
} from "./copy";

const KINDS: TrainingAnnouncementKind[] = ["roll_call", "sparring"];

describe("copy presets", () => {
	it("pre-fills both kinds with the retired bot's wording", () => {
		expect(COPY_PRESETS.roll_call.title).toBe("Roll call {{date}}");
		expect(COPY_PRESETS.sparring.title).toBe("Sparring {{date}}");
		expect(COPY_PRESETS.roll_call.message).toContain("training tonight");
		expect(COPY_PRESETS.sparring.message).toContain("sparring");
	});

	it("asks for next Sunday in the sparring preset, with no weekday token", () => {
		// Sparring is always on Sundays, so the preset names the day in
		// plain words instead of spending the `{{weekday}}` token.
		expect(COPY_PRESETS.sparring.message).toContain("next Sunday");
		expect(COPY_PRESETS.sparring.message).not.toContain("{{weekday}}");
	});

	it("keeps the @everyone ping out of stored copy", () => {
		// The toggle owns the mention: `Copy.render/2` prepends the line, so a
		// stored literal would render twice when the toggle is on and read as a
		// dead mention when it is off.
		for (const kind of KINDS) {
			expect(COPY_PRESETS[kind].message).not.toContain("@everyone");
			expect(COPY_PRESETS[kind].title).not.toContain("@everyone");
		}
	});

	it("uses only the tokens the renderer accepts", () => {
		for (const kind of KINDS) {
			for (const token of COPY_PRESETS[kind].message.matchAll(/\{\{.*?\}\}/g)) {
				expect(MESSAGE_TOKENS).toContain(token[0]);
			}
			for (const token of COPY_PRESETS[kind].title.matchAll(/\{\{.*?\}\}/g)) {
				expect(TITLE_TOKENS).toContain(token[0]);
			}
		}
	});
});

describe("presentation vocabulary", () => {
	it("labels both kinds and their destinations", () => {
		expect(Object.keys(KIND_CHANNEL_LABELS).sort()).toEqual(
			KINDS.slice().sort(),
		);
	});

	it("names weekdays in ISO order, Monday first", () => {
		// `Announcement.weekday` is an Elixir `Date.day_of_week/1` value (1..7).
		// `Announcement.weekday` is an Elixir `Date.day_of_week/1` value (1..7),
		// so `WEEKDAY_NAMES` indexes directly and index 0 stays unused.
		expect(WEEKDAY_NAMES[1]).toBe("Monday");
		expect(WEEKDAY_NAMES[7]).toBe("Sunday");
	});

	it("documents the token vocabulary the sheet offers", () => {
		expect(MESSAGE_TOKENS).toEqual(["{{title}}", "{{date}}", "{{weekday}}"]);
		expect(TITLE_TOKENS).toEqual(["{{date}}", "{{weekday}}"]);
	});
});
