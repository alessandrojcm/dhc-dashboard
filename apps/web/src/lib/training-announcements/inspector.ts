/**
 * Occurrence inspector vocabulary for Training Announcements (ALE-333,
 * spec ALE-317 stories 26–28).
 *
 * Phoenix owns what happened — the `chain` steps it actually checked, the
 * `decidedBy` winner, the rendered copy, the delivery evidence. This module
 * decides only *words*: how each precedence step reads, which steps were
 * evaluated, and whether the item may offer per-date actions. Nothing here
 * re-derives the outcome — the inspector renders the payload as it arrived,
 * so the calendar, the rail and the inspector cannot disagree.
 *
 * Canonical precedence, highest first (ALE-308, renamed by ALE-311):
 *
 * - `roll_call`: bank holiday → paused announcement → skipped dates →
 *   copy change → announcement defaults;
 * - `sparring`: the same without the holiday step — Sunday sparring is
 *   confirmed with the venue and is never assumed cancelled.
 *
 * A bank holiday cannot be overridden, and a skip hides override copy
 * without deleting it. The payload's `chain` is the evaluated prefix up to
 * and including the decisive step; steps past the winner were never reached.
 */

import type { TrainingAnnouncementOccurrence } from "@dhc/api-client";

/** One precedence step, highest first. */
export type PrecedenceStep =
	| "holiday"
	| "disablement"
	| "suppression"
	| "override"
	| "defaults";

/** The canonical precedence order, highest first. */
export const PRECEDENCE_ORDER: readonly PrecedenceStep[] = [
	"holiday",
	"disablement",
	"suppression",
	"override",
	"defaults",
];

export const PRECEDENCE_LABELS = {
	holiday: "Bank holiday",
	disablement: "Paused announcement",
	suppression: "Skipped dates",
	override: "Copy change",
	defaults: "Announcement defaults",
} satisfies Record<PrecedenceStep, string>;

/**
 * What each step decides, in committee words. A bank holiday outranks every
 * exception for a roll call; a skip wins over changed copy.
 */
export const PRECEDENCE_DESCRIPTIONS = {
	holiday:
		"Roll calls never post on a bank holiday. Sparring ignores this step.",
	disablement: "A paused announcement posts nothing until it is resumed.",
	suppression:
		"A skipped date posts nothing, even when changed copy covers it.",
	override:
		"Changed copy replaces the title, the message, or both on its dates.",
	defaults: "The announcement's own title, message and @everyone setting.",
} satisfies Record<PrecedenceStep, string>;

/** One precedence row as the inspector shows it. */
export type PrecedenceRow = {
	step: PrecedenceStep;
	label: string;
	description: string;
	/** Whether Phoenix checked this step for this item. */
	evaluated: boolean;
	/** Whether this step decided the outcome. */
	decided: boolean;
};

/** The least the inspector needs to explain an outcome. */
export type InspectorChainInput = Pick<
	TrainingAnnouncementOccurrence,
	"chain" | "decidedBy"
>;

/**
 * The precedence rows for one `window` item, in canonical order. Rows come
 * from the payload's evaluated `chain` and `decidedBy` only — steps Phoenix
 * never reached read as unreached, never as recomputed.
 */
export function precedenceRows(item: InspectorChainInput): PrecedenceRow[] {
	const evaluated = new Set(item.chain);
	return PRECEDENCE_ORDER.map((step) => ({
		step,
		label: PRECEDENCE_LABELS[step],
		description: PRECEDENCE_DESCRIPTIONS[step],
		evaluated: evaluated.has(step),
		decided: item.decidedBy === step,
	}));
}

/** Whether the payload carries any evaluated precedence at all. */
export function hasEvaluatedChain(item: InspectorChainInput): boolean {
	return item.chain.length > 0;
}

/** The least the inspector needs to decide whether actions apply. */
export type InspectorActionInput = Pick<
	TrainingAnnouncementOccurrence,
	"subject" | "date" | "readOnly" | "delivery"
>;

/**
 * Whether the inspector may offer "skip this date" and "change copy for
 * this date". Only a future Announcement Occurrence without delivery
 * qualifies: past items keep their evidence, in-flight items are already
 * posting, and holiday notices are read-only.
 */
export function inspectorActionsAllowed(
	item: InspectorActionInput,
	today: string,
): boolean {
	if (item.subject !== "occurrence") return false;
	if (item.readOnly) return false;
	if (item.delivery !== null) return false;
	return item.date >= today;
}

/** One delivery checkpoint as the inspector shows it. */
export type EvidenceCheckpoint = {
	label: string;
	at: string;
};

/** The least the inspector needs to list delivery checkpoints. */
export type EvidenceCheckpointInput = NonNullable<
	TrainingAnnouncementOccurrence["delivery"]
>;

/**
 * The delivery checkpoints that have happened, oldest first. Missing
 * timestamps never render — an in-flight post simply has fewer of them.
 */
export function evidenceCheckpoints(
	delivery: EvidenceCheckpointInput,
): EvidenceCheckpoint[] {
	const checkpoints: EvidenceCheckpoint[] = [];
	if (delivery.frozenAt !== null)
		checkpoints.push({ label: "Frozen", at: delivery.frozenAt });
	if (delivery.postingStartedAt !== null)
		checkpoints.push({
			label: "Posting started",
			at: delivery.postingStartedAt,
		});
	if (delivery.messagePostedAt !== null)
		checkpoints.push({ label: "Message posted", at: delivery.messagePostedAt });
	if (delivery.threadCreatedAt !== null)
		checkpoints.push({ label: "Thread created", at: delivery.threadCreatedAt });
	if (delivery.concludedAt !== null)
		checkpoints.push({ label: "Concluded", at: delivery.concludedAt });
	return checkpoints;
}

/** Delivery states that read as still in flight. */
const IN_FLIGHT_STATES = new Set([
	"frozen",
	"posting_message",
	"message_posted",
	"creating_thread",
]);

/** Whether the delivery is still posting rather than concluded. */
export function isInFlightDelivery(
	delivery: EvidenceCheckpointInput | null,
): boolean {
	return delivery !== null && IN_FLIGHT_STATES.has(delivery.state);
}
