/**
 * How the dashboard names Intake Email types and placeholders (ALE-383).
 *
 * Phoenix owns which types exist, their kind, button label and placeholders
 * (`Dhc.BeginnersWorkshops.IntakeEmails.EmailType`); this module only words
 * them for the coordinator. Both tables are exhaustive over the generated
 * enums, so a new type or placeholder fails type checking here.
 */
import type {
	IntakeEmailKind,
	IntakeEmailPlaceholder,
	IntakeEmailType,
} from "@dhc/api-client";

export type IntakeEmailTypeCopy = {
	label: string;
	/** When the email is queued. */
	sentWhen: string;
	/** Who receives it. Always the person's own Waitlist email. */
	recipients: string;
};

export const INTAKE_EMAIL_TYPES = {
	contact_pay: {
		label: "Place offer: payment needed",
		sentWhen:
			"A person on the waitlist is offered a workshop place, automatically or by staff.",
		recipients: "The person offered a place.",
	},
	contact_confirm: {
		label: "Place offer: use workshop credit",
		sentWhen:
			"A person with workshop credit is offered a place and asked to confirm rather than pay.",
		recipients: "The person offered a place.",
	},
	place_confirmed_paid: {
		label: "Place confirmed — paid",
		sentWhen: "The person pays for their place.",
		recipients: "The person who paid.",
	},
	place_confirmed_carried: {
		label: "Place confirmed: credit used",
		sentWhen: "The person confirms their place using workshop credit.",
		recipients: "The person who confirmed.",
	},
	pre_workshop: {
		label: "Pre-workshop info",
		sentWhen:
			"At the payment deadline, or when a payment already in progress completes afterwards. Sent again if the workshop is rescheduled.",
		recipients: "Everyone with a paid place.",
	},
	rescheduled: {
		label: "Workshop rescheduled",
		sentWhen: "The workshop is rescheduled.",
		recipients: "Everyone still offered a place or confirmed to attend.",
	},
	follow_up: {
		label: "Follow-up",
		sentWhen: "At 10:00 the morning after attendance is confirmed.",
		recipients: "Everyone who attended.",
	},
	declined: {
		label: "Declined",
		sentWhen: "The person declines their place.",
		recipients: "The person who declined.",
	},
	deferred: {
		label: "Moved to a later workshop",
		sentWhen:
			"The person's payment is saved as credit for a later workshop, including after an attendance correction.",
		recipients: "The person moving to a later workshop.",
	},
	cancelled_with_refund: {
		label: "Place cancelled: refund requested",
		sentWhen:
			"The coordinator cancels the person's place and requests a refund.",
		recipients: "The person whose refund was requested.",
	},
	withdrawn_refunded: {
		label: "Withdrawn — refunded",
		sentWhen: "The person leaves the waitlist and a refund is requested.",
		recipients: "The withdrawn person.",
	},
	withdrawn_forfeited: {
		label: "Withdrawn: payment kept",
		sentWhen:
			"The person leaves the waitlist. Their payment is kept and cannot be used for a later workshop.",
		recipients: "The withdrawn person.",
	},
	carried_fee_refunded: {
		label: "Workshop credit: refund requested",
		sentWhen:
			"A refund is requested for the payment behind a person's workshop credit.",
		recipients: "The person whose credit refund was requested.",
	},
	payment_refunded: {
		label: "Automatic refund requested",
		sentWhen:
			"An automatic refund is requested (for example, a payment completed after the person's place closed).",
		recipients: "The person whose refund was requested.",
	},
	cancelled_paid: {
		label: "Workshop cancelled — paid",
		sentWhen:
			"The workshop is cancelled and payments are saved as credit for a later workshop.",
		recipients: "Everyone with a paid place.",
	},
	cancelled_unpaid: {
		label: "Workshop cancelled — unpaid",
		sentWhen: "The workshop is cancelled.",
		recipients: "Everyone contacted who hasn't paid.",
	},
} as const satisfies Record<IntakeEmailType, IntakeEmailTypeCopy>;

export const INTAKE_EMAIL_PLACEHOLDER_LABELS = {
	firstName: "First name",
	date: "Date",
	startTime: "Start time",
	venue: "Venue",
	fee: "Fee",
	windowEnd: "Reply deadline",
	paymentCutoff: "Payment deadline",
	refundAmount: "Refund amount",
} as const satisfies Record<IntakeEmailPlaceholder, string>;

export const INTAKE_EMAIL_KIND_GROUPS = [
	{ kind: "action", title: "Emails with a booking link" },
	{ kind: "notice", title: "Updates and cancellations" },
] as const satisfies readonly { kind: IntakeEmailKind; title: string }[];

/** "Never a Guardian": Guardians have no email address in the system. */
export const INTAKE_EMAIL_RECIPIENT_NOTE =
	"Sent to the email address on the person's waitlist record, not to a guardian. Replies go to the club's contact address.";
