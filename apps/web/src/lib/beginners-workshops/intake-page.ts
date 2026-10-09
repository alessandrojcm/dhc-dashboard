/**
 * ALE-381: how the public Intake page words Phoenix's safe view. Phoenix
 * decides the `state` and the one `action` (`Dhc.BeginnersWorkshops.IntakePage`);
 * this module only names them. Both records are exhaustive, so a new state
 * or action is a type error until its copy is decided. Dates and times are
 * Europe/Dublin civil values, shown as given.
 */
import type {
	BeginnersIntakeAction,
	BeginnersIntakePage,
	BeginnersIntakeState,
} from "@dhc/api-client";
import {
	formatCivilDate,
	formatFee,
} from "#lib/beginners-workshops/presentation.js";

/** What an unknown link shows: the same as a closed Intake. */
export const INACTIVE_PAGE: BeginnersIntakePage = {
	state: "closed",
	action: "none",
	closedReason: "inactive",
	firstName: null,
	workshop: null,
	feeCents: null,
};

/** How often `payment_in_progress` asks Phoenix again. */
export const REFRESH_MS = 3000;

type Copy = { title: string; body: string };

const STATE_COPY = {
	pay: {
		title: "Your place at the Beginners' Workshop",
		body: "Pay to confirm your place. Your seat is held for 30 minutes while you're in checkout.",
	},
	payment_in_progress: {
		title: "Payment in progress",
		body: "We're confirming your payment with Stripe. This page updates on its own — there's no need to pay again.",
	},
	full: {
		title: "The workshop is full right now",
		body: "Every seat is paid for or being paid for. Seats can free up before the payment deadline, so check again later.",
	},
	paid: {
		title: "Your place is confirmed",
		body: "You've paid — we've emailed you a confirmation. See you at the workshop!",
	},
	closed: {
		title: "This link is no longer active",
		body: "If you think this is a mistake, reply to the email you received and we'll help.",
	},
} satisfies Record<BeginnersIntakeState, Copy>;

const PAYMENT_CLOSED: Copy = {
	title: "Payment has closed",
	body: "The payment deadline for this workshop has passed. Reply to the email you received if you have questions.",
};

const ACTION_LABELS = {
	pay: "Pay for your place",
	continue_payment: "Continue to payment",
	check_again: "Check again",
	none: null,
} satisfies Record<BeginnersIntakeAction, string | null>;

/** The page's headline and explanation. */
export function intakeCopy(page: BeginnersIntakePage): Copy {
	if (page.state === "closed" && page.closedReason === "payment_closed") {
		return PAYMENT_CLOSED;
	}
	return STATE_COPY[page.state];
}

/** The one action's button label, or `null` when there is none. */
export function intakeActionLabel(page: BeginnersIntakePage): string | null {
	return ACTION_LABELS[page.action];
}

/** Whether the action starts or resumes Stripe Checkout. */
export function startsCheckout(page: BeginnersIntakePage): boolean {
	return page.action === "pay" || page.action === "continue_payment";
}

/** The workshop facts shown on the page, or `null` on an inactive link. */
export function intakeDetails(page: BeginnersIntakePage) {
	if (!page.workshop) return null;
	return {
		greeting: page.firstName ? `Hi ${page.firstName},` : null,
		date: formatCivilDate(page.workshop.date),
		time: page.workshop.startTime,
		venue: page.workshop.venue,
		fee: page.feeCents === null ? null : formatFee(page.feeCents),
	};
}
