import fixtures from "@dhc/email-templates/fixtures/intake-email-measure.json";
import type { IntakeEmailPlaceholder, IntakeEmailType } from "@dhc/api-client";
import { describe, expect, it } from "vitest";
import {
	escapeHtml,
	INTAKE_EMAIL_LIMIT,
	measureIntakeEmail,
	refusedSubjectTokens,
} from "./measure.js";

// SAFETY: renderer_test.exs runs the same fixtures through Phoenix, so every
// fixture `emailType` is an Intake Email type.
const fixtureType = (type: string) => type as IntakeEmailType;

// SAFETY: the fixture's `placeholders` table is checked against Phoenix's
// EmailType table by `renderer_test.exs`, and every key is an email type.
const placeholders = fixtures.placeholders as Record<
	IntakeEmailType,
	IntakeEmailPlaceholder[]
>;

describe("the shared Intake Email measure fixtures", () => {
	it("uses the fixture limit", () => {
		expect(INTAKE_EMAIL_LIMIT).toBe(fixtures.limit);
		expect(fixtures.unit).toBe("utf16");
	});

	for (const fixture of fixtures.cases) {
		it(`measures: ${fixture.name}`, () => {
			const allowed = placeholders[fixtureType(fixture.emailType)];
			const measure = measureIntakeEmail(fixture.body, allowed);

			expect(measure.html).toBe(fixture.expectedHtml);
			expect(measure.length).toBe(fixture.expectedLength);
			expect(measure.fits).toBe(fixture.fits);
			expect(measure.hasText).toBe(true);
			expect(measure.refused).toEqual([]);
		});
	}

	for (const fixture of fixtures.refusals) {
		it(`refuses: ${fixture.name}`, () => {
			const allowed = placeholders[fixtureType(fixture.emailType)];
			const measure = measureIntakeEmail(fixture.body, allowed);

			expect(measure.refused).toEqual(fixture.placeholders);
		});
	}
});

describe("measureIntakeEmail", () => {
	it("reports a body without visible text, like Phoenix", () => {
		expect(
			measureIntakeEmail({ type: "doc", content: [{ type: "paragraph" }] }, [
				"firstName",
			]),
		).toMatchObject({ html: "<p><br></p>", hasText: false });
	});
});

describe("refusedSubjectTokens", () => {
	it("names tokens the type can't fill, once each", () => {
		expect(
			refusedSubjectTokens("{{venue}} on {{date}} {{venue}} {{coach}}", [
				"firstName",
				"date",
			]),
		).toEqual(["venue", "coach"]);
	});
});

describe("escapeHtml", () => {
	it("escapes the characters Phoenix escapes", () => {
		expect(escapeHtml(`Tom & Jerry's <club> "pay"`)).toBe(
			"Tom &amp; Jerry&#39;s &lt;club&gt; &quot;pay&quot;",
		);
	});
});
