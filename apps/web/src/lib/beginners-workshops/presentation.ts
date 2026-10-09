/**
 * ALE-378: how the dashboard words Phoenix's Beginners' Workshop vocabulary.
 * The stage, seats and alerts are Phoenix's judgement (`WorkshopPolicy`);
 * this module only names them. Dates and times are Europe/Dublin civil
 * values and are formatted as given, never converted.
 */
import type {
	BeginnersWorkshopAlert,
	BeginnersWorkshopStage,
} from "@dhc/api-client";
import dayjs from "dayjs";

const STAGE_LABELS = {
	before_contact_from: "Waiting for the contact-from date",
	window_open: "Batch window open",
	next_batch_due: "Next Batch due",
	batches_paused: "Batches paused",
	full: "Full — waiting for the Payment Cutoff",
	payment_closed: "Payment closed",
	today_before_check_in: "Today — check-in opens an hour before",
	check_in_open: "Today — check-in open",
	awaiting_finalisation: "Awaiting finalisation",
	finalised: "Finalised",
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
	unstaffed: "Unstaffed: no coach assigned",
} satisfies Record<BeginnersWorkshopAlert, string>;

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

/** A civil `YYYY-MM-DD` as `Sat 14 Nov 2026` (dayjs reads it as local midnight). */
export function formatCivilDate(date: string): string {
	return dayjs(date).format("ddd D MMM YYYY");
}

/** The calendar tile parts of a civil date. */
export function dateTile(date: string) {
	const day = dayjs(date);
	return {
		weekday: day.format("ddd"),
		day: day.format("D"),
		month: day.format("MMM"),
	};
}
