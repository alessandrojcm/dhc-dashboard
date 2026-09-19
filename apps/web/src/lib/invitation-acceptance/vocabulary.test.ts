import { describe, expect, it } from "vitest";
import {
	acceptanceStepPresentation,
	presentAcceptanceStep,
} from "./presentation";
import * as v from "valibot";
import {
	acceptanceStateResponseSchema,
	invitationAcceptanceStatuses,
	normalizeAcceptanceStatus,
} from "./vocabulary";

const parseView = (
	body:
		| { data: Record<string, string | boolean> }
		| { errors: { detail: string } },
) => {
	const parsed = v.safeParse(acceptanceStateResponseSchema, body);
	return parsed.success ? parsed.output.data : undefined;
};

describe("Invitation Acceptance vocabulary", () => {
	it("collapses both Phoenix spellings onto one canonical status", () => {
		expect(normalizeAcceptanceStatus("awaiting_oauth")).toBe("awaitingDiscord");
		expect(normalizeAcceptanceStatus("awaitingDiscord")).toBe(
			"awaitingDiscord",
		);
		expect(normalizeAcceptanceStatus("restart_verification")).toBe(
			"restartVerification",
		);
		expect(normalizeAcceptanceStatus("restartVerification")).toBe(
			"restartVerification",
		);
	});

	it("rejects an unknown status rather than guessing", () => {
		expect(normalizeAcceptanceStatus("mystery")).toBeUndefined();
		expect(parseView({ data: { state: "mystery" } })).toBeUndefined();
		expect(parseView({ errors: { detail: "x" } })).toBeUndefined();
	});

	it("keeps the safe-view fields and never anything else", () => {
		expect(
			parseView({
				data: {
					state: "paymentPending",
					discordVerified: true,
					retryAllowed: false,
					attemptId: "leak",
				},
			}),
		).toEqual({
			state: "paymentPending",
			discordVerified: true,
			retryAllowed: false,
		});
	});
});

describe("Invitation Acceptance presentation", () => {
	it.each(invitationAcceptanceStatuses)(
		"%s has an intentional step, title, and description",
		(state) => {
			const presentation = presentAcceptanceStep(state);
			expect([1, 2, 3]).toContain(presentation.step);
			expect(presentation.title.length).toBeGreaterThan(0);
			expect(presentation.description.length).toBeGreaterThan(0);
		},
	);

	it("covers exactly the vocabulary", () => {
		expect(Object.keys(acceptanceStepPresentation).sort()).toEqual(
			[...invitationAcceptanceStatuses].sort(),
		);
	});
});
