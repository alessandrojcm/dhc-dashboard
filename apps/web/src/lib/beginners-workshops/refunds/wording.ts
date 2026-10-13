/**
 * ALE-421: how the refund module words Beginners' Workshop money — the
 * refund-or-forfeit choice, a failed refund and its follow-ups, the
 * refund-credit confirmation, and each command's outcome — once, for the
 * console and the Waitlist tab alike (where the two used to differ, the
 * console's wording won). Which command is offered, and for which money, is
 * Phoenix's (`refundChoice`, `availableCommands`); this only words it.
 */
import type {
	BeginnersWorkshopFailedRefundCommand,
	BeginnersWorkshopRefundChoice,
} from "@dhc/api-client";
import type { RefundScope } from "./scope.js";

/** The money commands the refund module runs, in either scope. */
export type RefundCommand =
	| "withdraw"
	| "delete_person"
	| "refund_credit"
	| BeginnersWorkshopFailedRefundCommand;

/** The follow-ups to a failed refund, in display order. */
export const FOLLOW_UPS = [
	"retry",
	"manual",
	"forfeit",
] as const satisfies readonly BeginnersWorkshopFailedRefundCommand[];

export type CommandOutcome = "done" | "already_done";

/** A refund amount: `€40.00`, or `12.50 GBP` outside euro. */
export function formatRefundAmount(cents: number, currency: string): string {
	const amount = (cents / 100).toFixed(2);
	return currency === "eur"
		? `€${amount}`
		: `${amount} ${currency.toUpperCase()}`;
}

/** Withdraw's promise, held once: the person may come back. */
export const RESTORE_WINDOW =
	"You can restore them to the waitlist for 3 months.";

/** What Withdraw does, in the scope it runs from. */
export function withdrawDescription(scope: RefundScope): string {
	const leaves =
		scope.kind === "workshop"
			? "They leave the waitlist and this workshop."
			: "They leave the waitlist and any current workshop place is closed.";
	return `${leaves} ${RESTORE_WINDOW} Their payment will not be saved as workshop credit.`;
}

/** What Delete does. */
export const DELETE_DESCRIPTION =
	"Their waitlist record, personal details and guardian details are permanently deleted. Workshop reports keep the counts without their name or contact details. Nobody is emailed.";

/** Withdraw with no money to settle, from a workshop place. */
export const NO_PAYMENT_TO_REFUND =
	"There is no payment to refund. Their place is closed and any checkout reservation is released. No email is sent.";

/**
 * The refund-or-forfeit question. Without Phoenix's `refundChoice` (a
 * refusal on `refund` from a stale read) the money is unknown: their fee.
 */
export function refundChoiceQuestion(
	choice: BeginnersWorkshopRefundChoice | null,
): string {
	return choice?.source === "carried_fee"
		? "What happens to their workshop credit?"
		: "What happens to their fee?";
}

/**
 * ALE-387/389: the refund option of the refund-or-forfeit choice — the full
 * amount the money originally took (`refundChoice`, from Phoenix), which for
 * workshop credit may differ from this workshop's fee.
 */
export function refundChoiceLabel(
	choice: BeginnersWorkshopRefundChoice | null,
): string {
	const what = choice?.source === "carried_fee" ? "their workshop credit" : "";
	if (!choice || choice.amountCents === null || choice.currency === null) {
		return what ? `Refund ${what} in full` : "Refund in full";
	}
	const amount = formatRefundAmount(choice.amountCents, choice.currency);
	return what ? `Refund ${what}: ${amount}` : `Refund ${amount}`;
}

/** What each option of the choice does: Withdraw emails the person, Delete nobody. */
export function refundChoiceOptions(command: "withdraw" | "delete_person"): {
	refund: string;
	forfeit: string;
} {
	return command === "withdraw"
		? {
				refund: "Refund their original payment and email them a confirmation.",
				forfeit:
					"No refund or workshop credit. They receive an email explaining this.",
			}
		: {
				refund: "Against their original payment.",
				forfeit: "Nothing is refunded.",
			};
}

/**
 * ALE-387 (story 77): the "less than N days to go" hint shown when choosing
 * between keeping the fee and refunding it. Phoenix works out the days left
 * on its own clock (`refundTimingDaysToGo`, 7 or fewer, `null` otherwise);
 * this only words them. There is no deadline: the club's policy is
 * informal, so this only reminds the coordinator how close the workshop is.
 */
export function refundTimingHint(
	daysToGo: number | null | undefined,
): string | null {
	if (daysToGo === null || daysToGo === undefined) return null;
	const when =
		daysToGo === 0
			? "The workshop is today"
			: daysToGo === 1
				? "The workshop is tomorrow"
				: `Less than ${daysToGo} days to go`;
	return `${when} — there's no deadline; whether to refund is your call.`;
}

/** The refund-credit confirmation's question. */
export function refundCreditQuestion(amount: string | null): string {
	return amount
		? `Refund ${amount} to the original payment?`
		: "Refund their workshop credit to the original payment?";
}

const REFUND_REASONS = new Map([
	["policy_failed", "the payment didn't match the fee"],
	["paid_after_close", "they paid after their place was closed"],
	["cancelled_with_refund", "cancelled with a refund"],
	["withdrawn", "withdrawn with a refund"],
	["carried_fee_refunded", "their workshop credit"],
]);

/** A failed refund, as either scope reads it. */
export type FailedRefund = {
	amountCents: number;
	currency: string;
	/** Why the refund was owed (`policy_failed`, …). */
	reason: string;
	/** Stripe's reason it failed, when Phoenix has one. */
	lastError?: string | null;
	/** Whether it refunds workshop credit. */
	carriedFee: boolean;
};

/**
 * A failed refund and what may follow it up. Forfeit is offered only while
 * the credit is available again; credit still owed back (the person has
 * since paid or holds other credit) can only be retried or recorded.
 */
export function failedRefundText(
	refund: FailedRefund,
	availableCommands: readonly string[],
	name: string | null,
): string {
	const why = refund.lastError || REFUND_REASONS.get(refund.reason);
	const next = availableCommands.includes("forfeit")
		? "Their workshop credit is available again. Retry the refund, record a refund paid outside the app, or keep the payment and remove the credit."
		: refund.carriedFee
			? "They have since paid or received another workshop credit, so this payment is still owed back. Retry the refund or record a refund paid outside the app."
			: "Retry the refund or record a refund paid outside the app.";
	const to = name ? ` to ${name}` : "";
	return `Refund of ${formatRefundAmount(refund.amountCents, refund.currency)}${to} failed${why ? ` (${why})` : ""}. ${next}`;
}

/** The follow-up buttons. */
export const FOLLOW_UP_LABELS = {
	retry: "Retry",
	manual: "Record manual refund",
	forfeit: "Remove credit, keep payment",
} satisfies Record<BeginnersWorkshopFailedRefundCommand, string>;

/** Record manual refund's explanation. */
export function manualRefundDescription(
	refund: Pick<FailedRefund, "amountCents" | "currency">,
	name: string | null,
): string {
	return `Record that you paid ${name ?? "them"} ${formatRefundAmount(refund.amountCents, refund.currency)} back outside Stripe. No email is sent.`;
}

const DONE = {
	withdraw: "Withdrawn from the Waitlist",
	delete_person:
		"Deleted. Their workshop places stay in the reports, anonymised",
	refund_credit:
		"Credit refund requested. They will need to pay for their next workshop",
	retry: "Refund sent to Stripe again",
	manual: "Manual refund recorded — no email sent",
	forfeit: "Workshop credit removed; payment kept",
} satisfies Record<RefundCommand, string>;

/** The toast after a command; a repeat that changed nothing says so. */
export function refundCommandDone(
	command: RefundCommand,
	outcome: CommandOutcome = "done",
): string {
	return outcome === "already_done"
		? "Already done — nothing changed"
		: DONE[command];
}

/** The message when Phoenix answers without a `detail`. */
export const REFUND_COMMAND_FALLBACK = {
	withdraw: "Could not withdraw this person",
	delete_person: "Could not delete this person",
	refund_credit: "Could not refund the workshop credit",
	retry: "Could not retry the refund",
	manual: "Could not record the manual refund",
	forfeit: "Could not forfeit the workshop credit",
} satisfies Record<RefundCommand, string>;
