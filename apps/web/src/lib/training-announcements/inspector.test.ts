import { describe, expect, it } from "vitest";
import type { TrainingAnnouncementOccurrence } from "@dhc/api-client";
import {
	evidenceCheckpoints,
	hasEvaluatedChain,
	inspectorActionsAllowed,
	isInFlightDelivery,
	occurrenceNotSentReason,
	precedenceRows,
	PRECEDENCE_ORDER,
} from "./inspector";

function item(
	overrides: Partial<TrainingAnnouncementOccurrence> = {},
): TrainingAnnouncementOccurrence {
	return {
		subject: "occurrence",
		date: "2026-10-08",
		announcementId: "11111111-1111-1111-1111-111111111111",
		appliedSuppressionId: null,
		appliedOverrideId: null,
		holidayDate: null,
		phase: null,
		postTime: "10:00:00",
		kind: "roll_call",
		outcome: "post",
		chain: ["holiday", "disablement", "suppression", "override", "defaults"],
		decidedBy: "defaults",
		titleSource: "Roll call {{date}}",
		messageSource: "Who is coming?",
		mentionEveryone: true,
		renderedMessage: "@everyone\nRoll call Thursday 8 October 2026",
		threadName: "Roll call Thursday 8 October 2026",
		readOnly: false,
		renderErrors: [],
		delivery: null,
		...overrides,
	};
}

function delivery(
	overrides: Partial<
		NonNullable<TrainingAnnouncementOccurrence["delivery"]>
	> = {},
): NonNullable<TrainingAnnouncementOccurrence["delivery"]> {
	return {
		id: "delivery-id",
		state: "delivered",
		reason: "unknown",
		frozenAt: "2026-10-08T09:59:00Z",
		postingStartedAt: "2026-10-08T10:00:00Z",
		messagePostedAt: "2026-10-08T10:00:05Z",
		threadCreatedAt: "2026-10-08T10:00:10Z",
		concludedAt: "2026-10-08T10:00:12Z",
		discordMessageId: "234567890123456789",
		discordThreadId: null,
		permalink: "https://discord.com/channels/1/2/234567890123456789",
		errorDetail: null,
		threadAttempts: 1,
		lastThreadError: null,
		appliedSuppressionId: null,
		appliedOverrideId: null,
		...overrides,
	};
}

describe("occurrenceNotSentReason", () => {
	it("shows only the reason for a non-posting outcome", () => {
		expect(occurrenceNotSentReason(item())).toBeNull();
		expect(
			occurrenceNotSentReason(item({ outcome: "post_override" })),
		).toBeNull();
		expect(occurrenceNotSentReason(item({ outcome: "skipped_holiday" }))).toBe(
			"Roll call isn’t sent on bank holidays.",
		);
		expect(occurrenceNotSentReason(item({ outcome: "skipped_disabled" }))).toBe(
			"This announcement is paused.",
		);
		expect(
			occurrenceNotSentReason(item({ outcome: "skipped_suppressed" })),
		).toBe("Skipped for this date.");
		expect(occurrenceNotSentReason(item({ outcome: "missed" }))).toBe(
			"The scheduled posting time was missed.",
		);
	});
	it("uses delivery facts over projected outcomes", () => {
		expect(
			occurrenceNotSentReason(
				item({
					outcome: "skipped_holiday",
					delivery: delivery({ state: "delivered" }),
				}),
			),
		).toBeNull();
		expect(
			occurrenceNotSentReason(
				item({
					delivery: delivery({ state: "skipped", reason: "suppressed" }),
				}),
			),
		).toBe("Skipped for this date.");
		expect(
			occurrenceNotSentReason(
				item({
					delivery: delivery({ state: "blocked", reason: "permission" }),
				}),
			),
		).toBe("Post not sent: Discord refused.");
	});
});

describe("precedenceRows", () => {
	it("follows the canonical order from bank holiday down to defaults", () => {
		expect(PRECEDENCE_ORDER).toEqual([
			"holiday",
			"disablement",
			"suppression",
			"override",
			"defaults",
		]);
		const rows = precedenceRows(item());
		expect(rows.map((row) => row.step)).toEqual([...PRECEDENCE_ORDER]);
	});

	it("marks the evaluated prefix and highlights the winner", () => {
		const rows = precedenceRows(
			item({ chain: ["disablement", "suppression"], decidedBy: "suppression" }),
		);
		const byStep = new Map(rows.map((row) => [row.step, row]));
		// The payload omits the holiday step for sparring-like chains; the
		// inspector shows it as unreached rather than inventing it.
		expect(byStep.get("holiday")?.evaluated).toBe(false);
		expect(byStep.get("disablement")?.evaluated).toBe(true);
		expect(byStep.get("suppression")?.evaluated).toBe(true);
		expect(byStep.get("suppression")?.decided).toBe(true);
		expect(byStep.get("override")?.evaluated).toBe(false);
		expect(byStep.get("override")?.decided).toBe(false);
		expect(byStep.get("defaults")?.evaluated).toBe(false);
	});

	it("reads a holiday skip as decided by the first step alone", () => {
		const rows = precedenceRows(
			item({ chain: ["holiday"], decidedBy: "holiday" }),
		);
		expect(rows.filter((row) => row.evaluated).map((row) => row.step)).toEqual([
			"holiday",
		]);
		expect(rows.find((row) => row.step === "holiday")?.decided).toBe(true);
	});

	it("reports an empty chain for legacy rows that kept only their outcome", () => {
		expect(hasEvaluatedChain(item({ chain: [], decidedBy: null }))).toBe(false);
		expect(hasEvaluatedChain(item())).toBe(true);
	});
});

describe("inspectorActionsAllowed", () => {
	const TODAY = "2026-10-01";

	it("allows actions only for a future occurrence without delivery", () => {
		expect(inspectorActionsAllowed(item(), TODAY)).toBe(true);
	});

	it("refuses past occurrences, delivered items and holiday notices", () => {
		expect(inspectorActionsAllowed(item({ date: "2026-09-24" }), TODAY)).toBe(
			false,
		);
		expect(inspectorActionsAllowed(item({ delivery: delivery() }), TODAY)).toBe(
			false,
		);
		expect(
			inspectorActionsAllowed(
				item({ subject: "holiday", announcementId: null, readOnly: true }),
				TODAY,
			),
		).toBe(false);
		expect(inspectorActionsAllowed(item({ readOnly: true }), TODAY)).toBe(
			false,
		);
	});
});

describe("evidenceCheckpoints", () => {
	it("lists the checkpoints that happened, oldest first", () => {
		const checkpoints = evidenceCheckpoints(delivery());
		expect(checkpoints.map((checkpoint) => checkpoint.label)).toEqual([
			"Message prepared",
			"Posting started",
			"Message posted",
			"Thread created",
			"Finished",
		]);
	});

	it("omits checkpoints that never happened for in-flight posts", () => {
		const checkpoints = evidenceCheckpoints(
			delivery({
				state: "posting_message",
				messagePostedAt: null,
				threadCreatedAt: null,
				concludedAt: null,
			}),
		);
		expect(checkpoints.map((checkpoint) => checkpoint.label)).toEqual([
			"Message prepared",
			"Posting started",
		]);
	});
});

describe("isInFlightDelivery", () => {
	it("reads frozen and posting states as in flight", () => {
		for (const state of [
			"frozen",
			"posting_message",
			"message_posted",
			"creating_thread",
		] as const) {
			expect(isInFlightDelivery(delivery({ state }))).toBe(true);
		}
	});

	it("reads concluded states and missing delivery as settled", () => {
		for (const state of [
			"delivered",
			"thread_failed",
			"message_uncertain",
			"blocked",
			"skipped",
			"missed",
		] as const) {
			expect(isInFlightDelivery(delivery({ state }))).toBe(false);
		}
		expect(isInFlightDelivery(null)).toBe(false);
	});
});
