import type { BeginnersWorkshopConsole } from "@dhc/api-client";
import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import WorkshopConsole from "./workshop-console.svelte";

const id = "6d9e6110-fc8c-4dcf-b64f-db21b20d5140";

function view(
	overrides: Partial<BeginnersWorkshopConsole> = {},
): BeginnersWorkshopConsole {
	return {
		workshop: {
			id,
			status: "scheduled",
			venue: "St. Andrew's Hall",
			date: "2026-11-14",
			startTime: "18:30",
			capacity: 3,
			feeCents: 4000,
			paymentCutoff: "2026-11-11T18:30:00Z",
			paymentCutoffDate: "2026-11-11",
			paymentCutoffTime: "18:30",
			contactFromDate: "2026-10-20",
			contactFromEditable: false,
			paymentWindowDays: 7,
			stage: "window_open",
			seats: { capacity: 3, paid: 1, holds: 0, free: 2 },
			alerts: [],
			staff: { coach: null, assistants: [] },
		},
		batches: [
			{
				number: 1,
				size: 3,
				sentAt: "2026-10-20T09:00:00Z",
				windowEndsAt: "2026-10-27T23:59:59.999999Z",
			},
		],
		pause: {
			paused: false,
			pausedAt: null,
			pausedBy: null,
			resumedAt: null,
			resumedBy: null,
		},
		nextBatch: {
			status: "scheduled",
			goesOutAt: "2026-10-28T10:00:00Z",
			number: 2,
			size: 2,
			capacity: 3,
			paid: 1,
			people: [
				{
					firstName: "Aoife",
					lastName: "Byrne",
					minor: false,
					queueDate: "2025-01-01T12:00:00Z",
				},
				{
					firstName: "Bea",
					lastName: "Kelly",
					minor: true,
					queueDate: "2025-02-01T12:00:00Z",
				},
			],
		},
		roster: {
			seated: [
				{
					id: "0b0c3b2e-8a43-4a8d-9a39-5b9d8a2ab001",
					state: "paid",
					origin: "batch",
					batchNumber: 1,
					firstName: "Cian",
					lastName: "Doyle",
					minor: false,
					queueDate: "2024-12-01T12:00:00Z",
					contactedAt: "2026-10-20T09:00:00Z",
					holdExpiresAt: null,
					checkedInAt: null,
					refund: null,
				},
			],
			asked: [
				{
					id: "0b0c3b2e-8a43-4a8d-9a39-5b9d8a2ab002",
					state: "contacted",
					origin: "batch",
					batchNumber: 1,
					firstName: "Dara",
					lastName: "Nolan",
					minor: true,
					queueDate: "2024-12-02T12:00:00Z",
					contactedAt: "2026-10-20T09:00:00Z",
					holdExpiresAt: null,
					checkedInAt: null,
					refund: null,
				},
			],
			out: [],
		},
		failedRefunds: [],
		attention: [],
		fastTrackOpen: true,
		...overrides,
	};
}

test("shows the Next Batch preview in priority order, minors badged, with Pause beside it", async () => {
	const screen = await render(WorkshopConsole, { view: view() });

	await expect
		.element(screen.getByTestId("next-batch-headline"))
		.toHaveTextContent("Batch 2 goes out Wed 28 Oct, 10:00");
	await expect
		.element(screen.getByTestId("next-batch-size"))
		.toHaveTextContent("3 seats − 1 paid = 2");

	const proposed = screen.getByRole("list", { name: "Proposed people" });
	const rows = proposed.getByRole("listitem");
	expect(rows.elements()).toHaveLength(2);
	await expect.element(rows.nth(0)).toHaveTextContent("Aoife Byrne");
	await expect.element(rows.nth(1)).toHaveTextContent("2 Bea Kelly Minor");
	await expect
		.element(screen.getByRole("button", { name: "Pause Batches" }))
		.toBeVisible();
});

test("groups the roster: seated, then asked, not paid yet", async () => {
	const screen = await render(WorkshopConsole, { view: view() });

	await expect
		.element(screen.getByRole("region", { name: "Asked, not paid yet" }))
		.toHaveTextContent("Dara Nolan");
	await expect
		.element(screen.getByRole("region", { name: "Seated (paid)" }))
		.toHaveTextContent("Cian Doyle");
	await expect
		.element(screen.getByRole("region", { name: "Now" }))
		.toHaveTextContent("Batch 1 window open — ends Tue 27 Oct, 23:59");
});

test("ALE-381: the seat meter counts live holds and each Intake shows when its hold runs out", async () => {
	const base = view();
	const screen = await render(WorkshopConsole, {
		view: view({
			workshop: {
				...base.workshop,
				stage: "full",
				seats: { capacity: 2, paid: 1, holds: 1, free: 0 },
			},
			roster: {
				...base.roster,
				asked: [
					{ ...base.roster.asked[0], holdExpiresAt: "2099-10-22T11:30:00Z" },
				],
			},
		}),
	});

	await expect
		.element(screen.getByTestId("seat-meter"))
		.toHaveTextContent("1 paid · 1 paying now · 0 free of 2");
	await expect
		.element(screen.getByTestId("hold-expiry"))
		.toHaveTextContent("Paying now · hold until 12:30");
	await expect
		.element(screen.getByRole("region", { name: "Seated (paid)" }))
		.toHaveTextContent("Cian Doyle");
});

test("paused Batches offer Resume and say who paused them", async () => {
	const base = view();
	const screen = await render(WorkshopConsole, {
		view: view({
			workshop: { ...base.workshop, stage: "batches_paused" },
			pause: {
				...base.pause,
				paused: true,
				pausedAt: "2026-10-21T11:00:00Z",
				pausedBy: "Róisín Walsh",
			},
			nextBatch: { ...base.nextBatch, status: "paused", goesOutAt: null },
		}),
	});

	await expect
		.element(screen.getByTestId("next-batch-headline"))
		.toHaveTextContent(/^Batches are paused/);
	await expect
		.element(screen.getByText("Paused Wed 21 Oct, 12:00 by Róisín Walsh"))
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Resume Batches" }))
		.toBeVisible();
});

test("free seats with nobody waiting need attention", async () => {
	const base = view();
	const screen = await render(WorkshopConsole, {
		view: view({
			workshop: { ...base.workshop, stage: "next_batch_due" },
			nextBatch: { ...base.nextBatch, status: "due", people: [] },
			attention: ["nobody_waiting"],
		}),
	});

	await expect
		.element(screen.getByRole("region", { name: "Needs attention" }))
		.toHaveTextContent("nobody is left waiting");
	await expect
		.element(screen.getByTestId("next-batch-headline"))
		.toHaveTextContent("Batch 2 is due, but nobody is waiting");
});

test("offers Fast-track only while Phoenix says it is open", async () => {
	const open = await render(WorkshopConsole, { view: view() });
	await expect
		.element(open.getByRole("button", { name: "Fast-track" }))
		.toBeEnabled();
	open.unmount();

	const closed = await render(WorkshopConsole, {
		view: view({ fastTrackOpen: false }),
	});
	await expect
		.element(closed.getByRole("button", { name: "Fast-track" }))
		.toBeDisabled();
});

test("shows a fast-tracked Intake's origin as Fast-track", async () => {
	const base = view();
	const screen = await render(WorkshopConsole, {
		view: view({
			roster: {
				...base.roster,
				asked: [
					{
						id: "1b2c3d4e-5f60-4718-8293-a4b5c6d7e8f9",
						state: "contacted",
						origin: "fast_track",
						batchNumber: null,
						firstName: "Ciara",
						lastName: "Referral",
						minor: false,
						queueDate: "2026-10-20T12:00:00Z",
						contactedAt: "2026-10-20T12:00:00Z",
						holdExpiresAt: null,
						checkedInAt: null,
						refund: null,
					},
				],
			},
		}),
	});
	const row = screen
		.getByRole("listitem")
		.filter({ hasText: "Ciara Referral" });
	await expect.element(row).toHaveTextContent("Fast-track");
});

test("ALE-382: a failed refund needs attention with Retry and Record manual refund, and rows show refund status", async () => {
	const base = view();
	const failed = "9a3f5a8e-2b1c-4d7e-8f90-1a2b3c4d5e6f";
	const screen = await render(WorkshopConsole, {
		view: view({
			roster: {
				...base.roster,
				asked: [
					{
						...base.roster.asked[0],
						refund: {
							status: "failed",
							method: "stripe",
							automatic: true,
							amountCents: 3500,
							currency: "eur",
						},
					},
				],
				seated: [
					{
						...base.roster.seated[0],
						refund: {
							status: "completed",
							method: "manual",
							automatic: true,
							amountCents: 4000,
							currency: "eur",
						},
					},
				],
			},
			failedRefunds: [
				{
					id: failed,
					intakeId: base.roster.asked[0].id,
					firstName: "Dara",
					lastName: "Nolan",
					amountCents: 3500,
					currency: "eur",
					reason: "policy_failed",
					failedAt: "2026-10-22T12:00:00Z",
				},
			],
		}),
	});

	const attention = screen.getByRole("region", { name: "Needs attention" });
	await expect
		.element(attention.getByTestId("failed-refund"))
		.toHaveTextContent("Refund of €35.00 to Dara Nolan failed");
	await expect
		.element(attention.getByRole("button", { name: "Retry" }))
		.toBeVisible();
	await expect
		.element(attention.getByRole("button", { name: "Record manual refund" }))
		.toBeVisible();

	await expect
		.element(
			screen
				.getByRole("region", { name: "Asked, not paid yet" })
				.getByTestId("refund-status"),
		)
		.toHaveTextContent("Refund failed");
	await expect
		.element(
			screen
				.getByRole("region", { name: "Seated (paid)" })
				.getByTestId("refund-status"),
		)
		.toHaveTextContent("Refunded manually");
});

test("ALE-394: Reschedule opens a dialog that says who it emails", async () => {
	const screen = await render(WorkshopConsole, { view: view() });

	await userEvent.click(screen.getByRole("button", { name: "Reschedule" }));
	// One seated and one asked: both open, both emailed.
	await expect
		.element(screen.getByTestId("reschedule-warning"))
		.toHaveTextContent("This emails 2 people “Workshop rescheduled”.");
});

test("ALE-394: a cancelled workshop offers no Reschedule", async () => {
	const base = view();
	const screen = await render(WorkshopConsole, {
		view: view({
			workshop: { ...base.workshop, status: "cancelled", stage: "cancelled" },
		}),
	});
	await expect
		.element(screen.getByRole("button", { name: "Reschedule" }))
		.not.toBeInTheDocument();
});
