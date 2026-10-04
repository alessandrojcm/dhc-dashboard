import { describe, expect, it } from "vitest";
import type { TrainingAnnouncementOccurrence } from "@dhc/api-client";
import {
	deliveryReasonLabel,
	occurrenceKey,
	occurrenceStatus,
	occurrenceTitle,
} from "./status";

type DeliveryState = NonNullable<
	TrainingAnnouncementOccurrence["delivery"]
>["state"];
type DeliveryReason = NonNullable<
	TrainingAnnouncementOccurrence["delivery"]
>["reason"];
type Outcome = TrainingAnnouncementOccurrence["outcome"];

const DELIVERY_STATES: DeliveryState[] = [
	"frozen",
	"posting_message",
	"message_posted",
	"creating_thread",
	"delivered",
	"message_uncertain",
	"thread_failed",
	"blocked",
	"skipped",
	"missed",
];

const DELIVERY_REASONS: DeliveryReason[] = [
	"holiday",
	"disabled",
	"suppressed",
	"unconfigured_channel",
	"invalid_copy",
	"late",
	"permission",
	"unknown_channel",
	"payload_rejected",
	"timeout",
	"server_error",
	"worker_lost",
	"unknown",
];

const OUTCOMES: Outcome[] = [
	"post",
	"post_override",
	"skipped_holiday",
	"skipped_disabled",
	"skipped_suppressed",
	"missed",
	"unknown",
];

function projected(
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
		chain: ["defaults"],
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

function evidenced(
	state: DeliveryState,
	reason: DeliveryReason,
): TrainingAnnouncementOccurrence {
	return projected({
		delivery: {
			id: "delivery-id",
			state,
			reason,
			frozenAt: "2026-10-08T09:59:00Z",
			postingStartedAt: null,
			messagePostedAt: null,
			threadCreatedAt: null,
			concludedAt: null,
			discordMessageId: null,
			discordThreadId: null,
			permalink: null,
			errorDetail: null,
			threadAttempts: 0,
			lastThreadError: null,
			appliedSuppressionId: null,
			appliedOverrideId: null,
		},
	});
}

describe("occurrenceStatus", () => {
	it("reads every in-flight delivery state as posting", () => {
		const inFlight: DeliveryState[] = [
			"frozen",
			"posting_message",
			"message_posted",
			"creating_thread",
		];
		for (const state of inFlight) {
			expect(occurrenceStatus(evidenced(state, "unknown"))).toEqual({
				label: "posting…",
				tone: "posting",
			});
		}
	});

	it("reads a delivered post as posted", () => {
		expect(occurrenceStatus(evidenced("delivered", "unknown")).label).toBe(
			"posted",
		);
	});

	it("reads a thread failure as posted without a thread", () => {
		// The message still reached members, so the wording must not sound
		// like the whole post failed.
		expect(occurrenceStatus(evidenced("thread_failed", "unknown"))).toEqual({
			label: "posted, no thread",
			tone: "posted",
		});
	});

	it("reads an uncertain delivery as uncertain", () => {
		const status = occurrenceStatus(evidenced("message_uncertain", "timeout"));
		expect(status.tone).toBe("uncertain");
		expect(status.label).toContain("ncertain");
	});

	it("words every blocked delivery with its cause", () => {
		for (const reason of DELIVERY_REASONS) {
			const status = occurrenceStatus(evidenced("blocked", reason));
			expect(status.tone).toBe("blocked");
			expect(status.label.startsWith("blocked")).toBe(true);
			// The cause must name the committee's next step, never leak raw
			// snake_case or an empty suffix.
			expect(status.label).not.toContain("_");
			expect(status.label.length).toBeGreaterThan("blocked — x".length);
		}
	});

	it("words every skipped delivery with its cause", () => {
		for (const reason of DELIVERY_REASONS) {
			const status = occurrenceStatus(evidenced("skipped", reason));
			expect(status.tone).toBe("skipped");
			expect(status.label.startsWith("skipped")).toBe(true);
			expect(status.label).not.toContain("_");
		}
	});

	it("words every missed delivery with its cause", () => {
		for (const reason of DELIVERY_REASONS) {
			const status = occurrenceStatus(evidenced("missed", reason));
			expect(status.tone).toBe("missed");
			expect(status.label.startsWith("missed")).toBe(true);
			expect(status.label).not.toContain("_");
		}
	});

	it("names the bank-holiday, pause and skip reasons in committee words", () => {
		expect(deliveryReasonLabel("holiday")).toContain("bank holiday");
		expect(deliveryReasonLabel("disabled")).toContain("paus");
		expect(deliveryReasonLabel("suppressed")).toContain("skip");
		expect(deliveryReasonLabel("unconfigured_channel")).toContain("channel");
		expect(deliveryReasonLabel("invalid_copy")).toContain("copy");
	});

	it("covers every raw delivery state", () => {
		for (const state of DELIVERY_STATES) {
			const status = occurrenceStatus(evidenced(state, "unknown"));
			expect(status.label.length).toBeGreaterThan(0);
		}
	});

	it("lets durable evidence win over the projection", () => {
		// A delivered row on a date the projection would skip still reads as
		// posted: history is never re-projected.
		const item = evidenced("delivered", "unknown");
		item.outcome = "skipped_suppressed";
		expect(occurrenceStatus(item).label).toBe("posted");
	});

	it("labels every projected outcome without evidence", () => {
		const labels = {
			post: "scheduled",
			post_override: "override",
			skipped_holiday: "bank holiday",
			skipped_disabled: "paused",
			skipped_suppressed: "skipped",
			missed: "missed",
			unknown: "unknown",
		} satisfies Record<Outcome, string>;
		for (const outcome of OUTCOMES) {
			expect(occurrenceStatus(projected({ outcome })).label).toBe(
				labels[outcome],
			);
		}
	});

	it("marks a future holiday announcement as a read-only holiday notice", () => {
		const status = occurrenceStatus(
			projected({
				subject: "holiday",
				announcementId: null,
				holidayDate: "2026-10-26",
				phase: "same_day",
				kind: null,
				outcome: "post",
				chain: ["holiday"],
				readOnly: true,
			}),
		);
		expect(status.tone).toBe("holiday");
		expect(status.label).toContain("oliday");
	});

	it("reads a past holiday announcement from its delivery evidence", () => {
		const item = evidenced("delivered", "holiday");
		item.subject = "holiday";
		item.announcementId = null;
		expect(occurrenceStatus(item).label).toBe("posted");
	});
});

describe("occurrenceTitle", () => {
	it("prefers the resolved thread name Phoenix computed", () => {
		expect(occurrenceTitle(projected())).toBe(
			"Roll call Thursday 8 October 2026",
		);
	});

	it("falls back to the kind when rendering failed", () => {
		expect(
			occurrenceTitle(projected({ threadName: null, kind: "sparring" })),
		).toBe("Sparring post");
		expect(
			occurrenceTitle(
				projected({ threadName: null, subject: "holiday", kind: null }),
			),
		).toBe("Holiday notice");
	});
});

describe("occurrenceKey", () => {
	it("identifies an occurrence by announcement and send date", () => {
		expect(occurrenceKey(projected())).toBe(
			"occurrence:11111111-1111-1111-1111-111111111111:2026-10-08",
		);
	});

	it("identifies a holiday item by holiday date and phase", () => {
		expect(
			occurrenceKey(
				projected({
					subject: "holiday",
					announcementId: null,
					holidayDate: "2026-10-26",
					phase: "day_before",
				}),
			),
		).toBe("holiday:2026-10-26:day_before");
	});
});
