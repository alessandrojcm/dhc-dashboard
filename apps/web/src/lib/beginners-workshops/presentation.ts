/**
 * ALE-378: how the dashboard words Phoenix's Beginners' Workshop vocabulary.
 * The stage, seats and alerts are Phoenix's judgement (`WorkshopPolicy`);
 * this module only names them. Dates and times are Europe/Dublin civil
 * values and are formatted as given, never converted.
 */
import type {
	BeginnersWorkshopAlert,
	BeginnersWorkshopStaff,
	BeginnersWorkshopStaffRole,
	BeginnersWorkshopStage,
} from "@dhc/api-client";

const STAGE_LABELS = {
	before_contact_from: "Offer emails have not started yet",
	window_open: "Waiting for replies to place offers",
	next_batch_due: "Next round of offers due",
	batches_paused: "Automatic offers paused",
	full: "Full — payments remain open until the deadline",
	payment_closed: "Payment deadline passed",
	today_before_check_in: "Today — check-in opens an hour before",
	check_in_open: "Today — check-in open",
	awaiting_finalisation: "Attendance not yet confirmed",
	finalised: "Attendance confirmed",
	cancelled: "Cancelled",
} satisfies Record<BeginnersWorkshopStage, string>;

const STAGE_TONES = {
	before_contact_from: "neutral",
	window_open: "neutral",
	next_batch_due: "attention",
	batches_paused: "warning",
	full: "neutral",
	payment_closed: "neutral",
	today_before_check_in: "live",
	check_in_open: "live",
	awaiting_finalisation: "warning",
	finalised: "neutral",
	cancelled: "ended",
} satisfies Record<
	BeginnersWorkshopStage,
	"neutral" | "attention" | "warning" | "live" | "ended"
>;

const ALERT_LABELS = {
	unstaffed: "No coach or assistants assigned",
} satisfies Record<BeginnersWorkshopAlert, string>;

const STAFF_ROLE_LABELS = {
	coach: "Coach",
	assistant: "Assistant",
} satisfies Record<BeginnersWorkshopStaffRole, string>;

export function staffRoleLabel(role: BeginnersWorkshopStaffRole): string {
	return STAFF_ROLE_LABELS[role];
}

/** `Aoife (coach), Brian, Cara`, or `No Staff yet`. */
export function staffSummary(staff: BeginnersWorkshopStaff): string {
	const names = [
		...(staff.coach ? [`${staff.coach.name} (coach)`] : []),
		...staff.assistants.map((assistant) => assistant.name),
	];
	return names.length ? names.join(", ") : "No coach or assistants assigned";
}

export type StageTone = (typeof STAGE_TONES)[BeginnersWorkshopStage];

export function stageLabel(stage: BeginnersWorkshopStage): string {
	return STAGE_LABELS[stage];
}

export function stageTone(stage: BeginnersWorkshopStage): StageTone {
	return STAGE_TONES[stage];
}

export function alertLabel(alert: BeginnersWorkshopAlert): string {
	return ALERT_LABELS[alert];
}

const euro = new Intl.NumberFormat("en-IE", {
	style: "currency",
	currency: "EUR",
});

/** `4000` → `€40.00`. */
export function formatFee(cents: number): string {
	return euro.format(cents / 100);
}

/** Euro for a form's fee input (`4000` → `40`). */
export function feeInEuro(cents: number): number {
	return cents / 100;
}
