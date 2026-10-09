// ALE-397: wording for the Dashboard tab's Beginners' Workshop report. Pure;
// every figure is Phoenix's (`GET /api/beginners-workshops/report`), so
// nothing here computes a count or a rate, it only says them.
import type {
	BeginnersWorkshopReportCarriedFees,
	BeginnersWorkshopReportExitsAfterPaying,
	BeginnersWorkshopReportExitsBeforePaying,
	BeginnersWorkshopReportGroup,
	BeginnersWorkshopReportRate,
} from "@dhc/api-client";
import { formatFee } from "#lib/beginners-workshops/presentation.js";

const NONE = "—";
const percent = new Intl.NumberFormat("en-IE", {
	style: "percent",
	maximumFractionDigits: 0,
});
const decimal = new Intl.NumberFormat("en-IE", { maximumFractionDigits: 1 });

/** A rate as a percentage; `—` when nobody could take the step (or cancelled). */
export function formatRate(rate: BeginnersWorkshopReportRate | undefined) {
	return rate === null || rate === undefined ? NONE : percent.format(rate);
}

/** A count of days: `1 day`, `20.5 days`, `—` when there is nothing to measure. */
export function formatDays(days: number | null): string {
	if (days === null) return NONE;
	return `${decimal.format(days)} ${days === 1 ? "day" : "days"}`;
}

/** A plain figure, `—` when there is nothing to measure. */
export function formatFigure(value: number | null): string {
	return value === null ? NONE : decimal.format(value);
}

/** `2 · 22%`: an exit count beside its rate (the count alone when there is no rate). */
export function countWithRate(
	count: number,
	rate: BeginnersWorkshopReportRate,
): string {
	return rate === null ? String(count) : `${count} · ${formatRate(rate)}`;
}

/** The outstanding Carried Fees' footnote: total originally paid, unlinked ones named. */
export function carriedFeesNote(fees: BeginnersWorkshopReportCarriedFees) {
	const total = `${formatFee(fees.totalPaidCents)} originally paid`;
	return fees.unlinked > 0
		? `${total} · ${fees.unlinked} not linked to a payment yet`
		: total;
}

/** `Batch 2` or `Fast-tracks`. */
export function groupLabel(group: BeginnersWorkshopReportGroup): string {
	return group.kind === "batch" ? `Batch ${group.number}` : "Fast-tracks";
}

/** What the exits before paying were made of, skipping empty kinds. */
export function exitsBeforePayingDetail({
	declined,
	lapsed,
	returned,
	withdrawn,
}: BeginnersWorkshopReportExitsBeforePaying): string {
	return detail([
		[declined, "declined"],
		[lapsed, "lapsed"],
		[returned, "returned"],
		[withdrawn, "withdrawn"],
	]);
}

/** What the exits after paying were made of, skipping empty kinds. */
export function exitsAfterPayingDetail({
	deferred,
	cancelledRefunded,
	withdrawn,
}: BeginnersWorkshopReportExitsAfterPaying): string {
	return detail([
		[deferred, "deferred"],
		[cancelledRefunded, "refunded"],
		[withdrawn, "withdrawn"],
	]);
}

function detail(parts: [number, string][]): string {
	return parts
		.filter(([count]) => count > 0)
		.map(([count, label]) => `${count} ${label}`)
		.join(" · ");
}
