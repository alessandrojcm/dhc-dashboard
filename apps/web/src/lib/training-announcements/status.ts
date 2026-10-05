/**
 * Shared display vocabulary for Training Announcement occurrences (ALE-332,
 * spec ALE-317 stories 32–35).
 *
 * Phoenix owns what happened — the raw delivery `state`, the `reason`, the
 * projected `outcome`, the resolved thread name. This module decides only how
 * those facts *read* on screen, so the calendar chips, the rail cards and (in
 * ALE-333) the occurrence inspector cannot disagree about what "posted, no
 * thread" means. Nothing here decides whether a post goes out.
 *
 * Grouping, in committee words:
 *
 * - in-flight delivery (`frozen`, `posting_message`, `message_posted`,
 *   `creating_thread`) reads as "posting…";
 * - `delivered` reads as "posted";
 * - `thread_failed` reads as "posted, no thread" — the message reached
 *   members, only the thread is missing;
 * - `message_uncertain` reads as uncertain and points at Discord, because the
 *   worker deliberately never reposts an ambiguous result;
 * - `blocked`, `skipped` and `missed` name the committee's next step through
 *   the delivery `reason`;
 * - a future projection reads from its `outcome`: scheduled, override, bank
 *   holiday, paused, skipped, missed, or unknown.
 *
 * Durable evidence always wins: an item carrying `delivery` is read from that
 * row even when the projection now resolves differently, because history is
 * never re-projected.
 */
import type { TrainingAnnouncementOccurrence } from "@dhc/api-client";
import { KIND_LABELS } from "./copy";

type DeliveryState = NonNullable<
	TrainingAnnouncementOccurrence["delivery"]
>["state"];

type DeliveryReason = NonNullable<
	TrainingAnnouncementOccurrence["delivery"]
>["reason"];

/** The least an occurrence read needs to be labelled. */
export type OccurrenceStatusInput = Pick<
	TrainingAnnouncementOccurrence,
	"subject" | "outcome" | "delivery"
>;

/** The least a chip or card needs to name an occurrence. */
export type OccurrenceTitleInput = Pick<
	TrainingAnnouncementOccurrence,
	"subject" | "kind" | "threadName"
>;

/** The least the calendar needs to key an event. */
export type OccurrenceKeyInput = Pick<
	TrainingAnnouncementOccurrence,
	"subject" | "announcementId" | "date" | "holidayDate" | "phase"
>;

/**
 * Stable tone token for CSS classes. One token per visual group — the wording
 * may carry a reason suffix while the colour stays grouped.
 */
export type OccurrenceTone =
	| "scheduled"
	| "override"
	| "skipped"
	| "posting"
	| "posted"
	| "uncertain"
	| "blocked"
	| "missed"
	| "unknown"
	| "holiday";

export type OccurrenceStatus = {
	label: string;
	tone: OccurrenceTone;
};

function deliveryStatus(
	state: DeliveryState,
	reason: DeliveryReason,
): OccurrenceStatus {
	switch (state) {
		case "frozen":
		case "posting_message":
		case "message_posted":
		case "creating_thread":
			return { label: "posting…", tone: "posting" };
		case "delivered":
			return { label: "posted", tone: "posted" };
		case "thread_failed":
			return { label: "posted, no thread", tone: "posted" };
		case "message_uncertain":
			return { label: "uncertain — check Discord", tone: "uncertain" };
		case "blocked":
			return {
				label: `blocked — ${deliveryReasonLabel(reason)}`,
				tone: "blocked",
			};
		case "skipped":
			return {
				label: `skipped — ${deliveryReasonLabel(reason)}`,
				tone: "skipped",
			};
		case "missed":
			return {
				label: `missed — ${deliveryReasonLabel(reason)}`,
				tone: "missed",
			};
	}
}

/** Every raw delivery reason, in the committee's next-step words. */
export function deliveryReasonLabel(reason: DeliveryReason): string {
	// Phoenix retains rows whose reason was never established; they read as
	// unknown rather than leaking an empty suffix.
	if (reason === null) return "unknown reason";
	switch (reason) {
		case "holiday":
			return "bank holiday";
		case "disabled":
			return "paused announcement";
		case "suppressed":
			return "skipped dates";
		case "unconfigured_channel":
			return "channel not configured";
		case "invalid_copy":
			return "invalid message text";
		case "late":
			return "too late to post";
		case "permission":
			return "Discord refused";
		case "unknown_channel":
			return "unknown channel";
		case "payload_rejected":
			return "Discord rejected the message";
		case "timeout":
			return "Discord timed out";
		case "server_error":
			return "Discord error";
		case "worker_lost":
			return "posting process interrupted";
		case "unknown":
			return "unknown reason";
	}
}

/** The grouped display status of one `window` item. */
export function occurrenceStatus(
	item: OccurrenceStatusInput,
): OccurrenceStatus {
	if (item.delivery) {
		return deliveryStatus(item.delivery.state, item.delivery.reason);
	}
	if (item.subject === "holiday") {
		return { label: "holiday notice", tone: "holiday" };
	}
	switch (item.outcome) {
		case "post":
			return { label: "scheduled", tone: "scheduled" };
		case "post_override":
			return { label: "text changed", tone: "override" };
		case "skipped_holiday":
			return { label: "bank holiday", tone: "skipped" };
		case "skipped_disabled":
			return { label: "paused", tone: "skipped" };
		case "skipped_suppressed":
			return { label: "skipped", tone: "skipped" };
		case "missed":
			return { label: "missed", tone: "missed" };
		case "unknown":
			return { label: "unknown", tone: "unknown" };
	}
}

/**
 * The resolved title of one `window` item: the thread name Phoenix computed,
 * never the announcement's template. When rendering failed and there is no
 * resolved name, the kind (or the holiday notice) stands in rather than an
 * empty chip.
 */
export function occurrenceTitle(item: OccurrenceTitleInput): string {
	if (item.threadName) return item.threadName;
	if (item.subject === "holiday") return "Holiday notice";
	if (item.kind) return `${KIND_LABELS[item.kind]} post`;
	return "Training post";
}

/**
 * The calendar event id for one `window` item, mirroring the backend's
 * durable identity: an occurrence belongs to its announcement and send date,
 * a holiday item to its bank-holiday date and phase.
 */
export function occurrenceKey(item: OccurrenceKeyInput): string {
	if (item.subject === "holiday") {
		return `holiday:${item.holidayDate}:${item.phase}`;
	}
	return `occurrence:${item.announcementId}:${item.date}`;
}
