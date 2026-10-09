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
		label: "Contact — pay",
		sentWhen:
			"An Intake is created: the person's Batch goes out, or they are fast-tracked.",
		recipients: "The contacted person.",
	},
	contact_confirm: {
		label: "Contact — confirm (Carried Fee)",
		sentWhen: "An Intake is created for someone holding a Carried Fee.",
		recipients: "The contacted Carried Fee holder.",
	},
	place_confirmed_paid: {
		label: "Place confirmed — paid",
		sentWhen: "The person pays for their place.",
		recipients: "The person who paid.",
	},
	place_confirmed_carried: {
		label: "Place confirmed — Carried Fee",
		sentWhen: "The person confirms their place with a Carried Fee.",
		recipients: "The person who confirmed.",
	},
	pre_workshop: {
		label: "Pre-workshop info",
		sentWhen:
			"At the Payment Cutoff, or straight away for anyone who pays after it. Once per schedule.",
		recipients: "Everyone with a paid place.",
	},
	rescheduled: {
		label: "Workshop rescheduled",
		sentWhen: "The workshop is rescheduled.",
		recipients: "Everyone with an open Intake.",
	},
	follow_up: {
		label: "Follow-up",
		sentWhen: "At 10:00 the morning after attendance is finalised.",
		recipients: "Everyone who attended.",
	},
	declined: {
		label: "Declined",
		sentWhen: "The person declines their place.",
		recipients: "The person who declined.",
	},
	deferred: {
		label: "Deferred",
		sentWhen:
			"The person is deferred to a later workshop, including a no-show corrected to deferred.",
		recipients: "The deferred person.",
	},
	cancelled_with_refund: {
		label: "Cancelled with refund",
		sentWhen: "The coordinator cancels the person's place with a refund.",
		recipients: "The refunded person.",
	},
	withdrawn_refunded: {
		label: "Withdrawn — refunded",
		sentWhen: "The person is withdrawn and their fee refunded.",
		recipients: "The withdrawn person.",
	},
	withdrawn_forfeited: {
		label: "Withdrawn — forfeited",
		sentWhen: "The person is withdrawn and their fee forfeited.",
		recipients: "The withdrawn person.",
	},
	carried_fee_refunded: {
		label: "Carried Fee refunded",
		sentWhen: "A Carried Fee is refunded.",
		recipients: "The Carried Fee holder.",
	},
	payment_refunded: {
		label: "Payment refunded",
		sentWhen:
			"A payment is refunded automatically (for example, it arrived too late).",
		recipients: "The refunded person.",
	},
	cancelled_paid: {
		label: "Workshop cancelled — paid",
		sentWhen: "The workshop is cancelled; paid places are deferred.",
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
	windowEnd: "Window end",
	paymentCutoff: "Payment Cutoff",
	refundAmount: "Refund amount",
} as const satisfies Record<IntakeEmailPlaceholder, string>;

export const INTAKE_EMAIL_KIND_GROUPS = [
	{ kind: "action", title: "With a button (open Intakes)" },
	{ kind: "notice", title: "Notices (closed Intakes)" },
] as const satisfies readonly { kind: IntakeEmailKind; title: string }[];

/** "Never a Guardian": Guardians have no email address in the system. */
export const INTAKE_EMAIL_RECIPIENT_NOTE =
	"Sent to the person's own Waitlist email, never a Guardian. Replies go to the club's contact address.";
