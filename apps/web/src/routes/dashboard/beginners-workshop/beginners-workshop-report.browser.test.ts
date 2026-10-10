import type {
	BeginnersWorkshopReport,
	BeginnersWorkshopReportOutcome,
} from "@dhc/api-client";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import Report from "./beginners-workshop-report.svelte";

const finalised: BeginnersWorkshopReportOutcome = {
	workshopId: "6d9e6110-fc8c-4dcf-b64f-db21b20d5140",
	date: "2026-11-14",
	venue: "St. Andrew's Hall",
	status: "finalised",
	batchesSent: 1,
	contacted: { total: 9, batch: 7, fastTrack: 2 },
	exitsBeforePaying: {
		declined: 1,
		lapsed: 1,
		returned: 0,
		withdrawn: 0,
		total: 2,
		rate: 2 / 9,
	},
	paid: { total: 7, carriedFee: 1 },
	exitsAfterPaying: {
		deferred: 1,
		cancelledRefunded: 0,
		withdrawn: 0,
		total: 1,
		rate: 1 / 7,
	},
	attendance: { seated: 6, attended: 4, noShow: 2, rate: 4 / 6 },
	afterAttending: { invitable: 1, invitedNotJoined: 1, joined: 2 },
	conversionRate: 0.5,
	groups: [
		{
			kind: "batch",
			number: 1,
			windowEndsAt: "2026-10-27T23:59:59.999999Z",
			contacted: 7,
			paidInWindow: 4,
			paidLater: 1,
			declined: 1,
			unpaidAtCutoff: 1,
		},
		{
			kind: "fast_track",
			number: null,
			windowEndsAt: null,
			contacted: 2,
			paidInWindow: 2,
			paidLater: 0,
			declined: 0,
			unpaidAtCutoff: 0,
		},
	],
};

const cancelled: BeginnersWorkshopReportOutcome = {
	...finalised,
	workshopId: "7e0f7221-fc8c-4dcf-b64f-db21b20d5141",
	date: "2026-11-21",
	status: "cancelled",
	batchesSent: 0,
	contacted: { total: 2, batch: 0, fastTrack: 2 },
	exitsBeforePaying: { ...finalised.exitsBeforePaying, rate: null },
	exitsAfterPaying: { ...finalised.exitsAfterPaying, rate: null },
	attendance: { seated: 0, attended: 0, noShow: 0, rate: null },
	afterAttending: { invitable: 0, invitedNotJoined: 0, joined: 0 },
	conversionRate: null,
	groups: [],
};

const report = (
	overrides: Partial<BeginnersWorkshopReport> = {},
): BeginnersWorkshopReport => ({
	queue: {
		waiting: 4,
		medianWaitDays: 20,
		longestWaitDays: 180,
		medianDaysToSeat: 274.5,
		workshopsToClear: 1,
		removedInRetention: 1,
		invitable: 1,
		carriedFees: { count: 2, totalPaidCents: 3500, unlinked: 1 },
	},
	twelveMonths: {
		workshops: 1,
		attended: 4,
		joined: 2,
		invitable: 1,
		invitedNotJoined: 1,
		averageAttendees: 4,
		conversionRate: 0.5,
	},
	outcomes: [cancelled, finalised],
	...overrides,
});

test("ALE-397: planning cards show the 12-month figures and the liabilities", async () => {
	const screen = await render(Report, { report: report() });

	const card = (label: string) =>
		screen.getByTestId("report-card").filter({ hasText: label });

	await expect.element(card("Time to a seat")).toHaveTextContent("274.5 days");
	await expect
		.element(card("Workshops to clear the queue"))
		.toHaveTextContent("4 waiting ÷ 4 attendees per workshop");
	await expect
		.element(card("Conversion Rate"))
		.toHaveTextContent(
			"50% 2 joined of 4 attended · 1 Invitable · 1 invited, not yet joined",
		);
	await expect
		.element(card("Outstanding Carried Fees"))
		.toHaveTextContent(
			"€35.00 originally paid · 1 not linked to a payment yet",
		);
	await expect
		.element(card("Removed, within retention"))
		.toHaveTextContent("1");
});

test("ALE-397: outcomes list each workshop with its rates; cancelled ones have none", async () => {
	const screen = await render(Report, { report: report() });

	const rows = screen.getByTestId("report-outcome");
	expect(rows.elements()).toHaveLength(2);

	const done = rows.filter({ hasText: "Sat 14 Nov 2026" });
	await expect.element(done).toHaveTextContent("2 · 22%");
	await expect.element(done).toHaveTextContent("1 declined · 1 lapsed");
	await expect.element(done).toHaveTextContent("1 with a Carried Fee");
	await expect.element(done).toHaveTextContent("67% 4 attended · 2 no-show");
	await expect
		.element(done)
		.toHaveTextContent("2 joined 1 Invitable · 1 invited, not yet joined");
	await expect.element(done).toHaveTextContent("50%");

	const off = rows.filter({ hasText: "Sat 21 Nov 2026" });
	await expect.element(off).toHaveTextContent("Cancelled");
	await expect.element(off).not.toHaveTextContent("%");
	await expect
		.element(off.getByRole("link", { name: "Console" }))
		.toHaveAttribute(
			"href",
			"/dashboard/beginners-workshop/workshops/7e0f7221-fc8c-4dcf-b64f-db21b20d5141",
		);

	// Report only: the only buttons expand rows.
	for (const button of screen.getByRole("button").elements())
		expect(button.getAttribute("aria-label")).toMatch(/^(Show|Hide) Batches/);
});

test("ALE-397: a row expands into its Batches and fast-tracks", async () => {
	const screen = await render(Report, { report: report() });

	expect(screen.getByTestId("report-group").elements()).toHaveLength(0);
	await screen
		.getByRole("button", { name: "Show Batches for Sat 14 Nov 2026" })
		.click();

	const groups = screen.getByTestId("report-group");
	expect(groups.elements()).toHaveLength(2);
	await expect
		.element(groups.filter({ hasText: "Batch 1" }))
		.toHaveTextContent("Batch 1 Window to Tue 27 Oct, 23:59 7 4 1 1 1");
	await expect
		.element(groups.filter({ hasText: "Fast-tracks" }))
		.toHaveTextContent("Fast-tracks 2 2 0 0 0");
});

test("ALE-397: says so when there are no past workshops", async () => {
	const screen = await render(Report, { report: report({ outcomes: [] }) });
	await expect
		.element(screen.getByText("No past workshops yet"))
		.toBeInTheDocument();
});
