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
			seats: {
				capacity: 3,
				paid: 1,
				holds: 0,
				free: 2,
				attended: 0,
				noShow: 0,
			},
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
					confirms: false,
				},
				{
					firstName: "Bea",
					lastName: "Kelly",
					minor: true,
					queueDate: "2025-02-01T12:00:00Z",
					confirms: false,
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
					standing: "waiting",
					medical: false,
					windowEndsAt: "2026-10-27T22:59:59.999999Z",
					linkGeneration: 1,
					emailLog: [],
					history: [],
					availableCommands: [],
					attendanceCorrections: [],
					paidVia: null,
					carriedFee: null,
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
					standing: "waiting",
					medical: false,
					windowEndsAt: "2026-10-27T22:59:59.999999Z",
					linkGeneration: 1,
					emailLog: [],
					history: [],
					availableCommands: [],
					attendanceCorrections: [],
					paidVia: null,
					carriedFee: null,
				},
			],
			attended: [],
			noShow: [],
			out: [],
		},
		failedRefunds: [],
		unpaidAfterWindow: [],
		unconfirmedCarriedFees: [],
		attention: [],
		fastTrackOpen: true,
		fastTrackHoldersOnly: false,
		finalisation: null,
		cancelPreview: null,
		cancellation: null,
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
				seats: {
					capacity: 2,
					paid: 1,
					holds: 1,
					free: 0,
					attended: 0,
					noShow: 0,
				},
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
						standing: "waiting",
						medical: false,
						windowEndsAt: "2026-10-27T22:59:59.999999Z",
						linkGeneration: 1,
						emailLog: [],
						history: [],
						availableCommands: [],
						attendanceCorrections: [],
						paidVia: null,
						carriedFee: null,
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

test("ALE-391: a finalised workshop reads attended / no-show and is read-only", async () => {
	const base = view();
	const [seated] = base.roster.seated;
	const [asked] = base.roster.asked;
	const screen = await render(WorkshopConsole, {
		view: view({
			workshop: {
				...base.workshop,
				status: "finalised",
				stage: "finalised",
				seats: { ...base.workshop.seats, attended: 1, noShow: 1 },
			},
			roster: {
				seated: [],
				asked: [],
				attended: [{ ...seated, state: "attended" }],
				noShow: [{ ...asked, state: "no_show" }],
				out: [],
			},
			fastTrackOpen: false,
			fastTrackHoldersOnly: false,
			finalisation: {
				at: "2026-11-14T20:05:00Z",
				by: "Aoife Coach",
				followUpAt: "2026-11-15T10:00:00Z",
				invitations: { attended: 2, invited: 1, joined: 0 },
			},
		}),
	});

	await expect
		.element(screen.getByTestId("seat-meter"))
		.toHaveTextContent("1 attended · 1 no-show of 3");
	await expect
		.element(screen.getByRole("region", { name: "Attended" }))
		.toHaveTextContent("Cian Doyle");
	await expect
		.element(screen.getByRole("region", { name: "No-show" }))
		.toHaveTextContent("Dara Nolan");
	await expect
		.element(screen.getByRole("region", { name: "Now" }))
		.toHaveTextContent("Finalised Sat 14 Nov, 20:05 by Aoife Coach");
	expect(
		screen.getByRole("button", { name: /Fast-track|Pause Batches/ }).elements(),
	).toHaveLength(0);
});

test("ALE-392: a finalised console offers Invite to each Invitable attendee and counts the handoff", async () => {
	const base = view();
	const [seated] = base.roster.seated;
	const attendee = (
		id: string,
		firstName: string,
		standing: "attended" | "invited" | "joined",
	) => ({ ...seated, id, firstName, state: "attended" as const, standing });
	const finalised = view({
		workshop: {
			...base.workshop,
			status: "finalised",
			stage: "finalised",
			seats: { ...base.workshop.seats, attended: 3, noShow: 0 },
		},
		roster: {
			seated: [],
			asked: [],
			attended: [
				attendee("0a5d4c9e-1111-4f3a-9b1e-7d2c3b4a5f60", "Aoife", "attended"),
				attendee("0a5d4c9e-2222-4f3a-9b1e-7d2c3b4a5f60", "Bea", "invited"),
				attendee("0a5d4c9e-3333-4f3a-9b1e-7d2c3b4a5f60", "Cian", "joined"),
			],
			noShow: [],
			out: [],
		},
		fastTrackOpen: false,
		fastTrackHoldersOnly: false,
		finalisation: {
			at: "2026-11-14T20:05:00Z",
			by: null,
			followUpAt: "2026-11-15T10:00:00Z",
			invitations: { attended: 3, invited: 1, joined: 1 },
		},
	});

	const screen = await render(WorkshopConsole, {
		view: finalised,
		canInvite: true,
	});

	await expect
		.element(screen.getByTestId("invitation-summary"))
		.toHaveTextContent("3 attended · 1 invited · 1 joined");
	const attended = screen.getByRole("region", { name: "Attended" });
	expect(
		attended.getByRole("button", { name: "Invite" }).elements(),
	).toHaveLength(1);
	await expect
		.element(
			attended
				.getByRole("listitem")
				.filter({ hasText: "Aoife" })
				.getByRole("button", {
					name: "Invite",
				}),
		)
		.toBeVisible();
	await expect
		.element(attended.getByRole("listitem").filter({ hasText: "Bea" }))
		.toHaveTextContent("Invited");
	await expect
		.element(attended.getByRole("listitem").filter({ hasText: "Cian" }))
		.toHaveTextContent("Joined");
});

test("ALE-392: without members.invite the attended list offers no Invite", async () => {
	const base = view();
	const screen = await render(WorkshopConsole, {
		view: view({
			workshop: { ...base.workshop, status: "finalised", stage: "finalised" },
			roster: {
				seated: [],
				asked: [],
				attended: [
					{ ...base.roster.seated[0], state: "attended", standing: "attended" },
				],
				noShow: [],
				out: [],
			},
			finalisation: {
				at: "2026-11-14T20:05:00Z",
				by: null,
				followUpAt: "2026-11-15T10:00:00Z",
				invitations: { attended: 1, invited: 0, joined: 0 },
			},
		}),
	});

	await expect
		.element(screen.getByRole("region", { name: "Attended" }))
		.toHaveTextContent("Cian Doyle");
	expect(
		screen.getByRole("button", { name: "Invite" }).elements(),
	).toHaveLength(0);
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

test("ALE-395: Cancel opens a dialog with Phoenix's deferred, returned and released counts", async () => {
	const screen = await render(WorkshopConsole, {
		view: view({ cancelPreview: { deferred: 1, returned: 1, released: 0 } }),
	});

	await userEvent.click(
		screen.getByRole("button", { name: "Cancel workshop" }),
	);
	const preview = screen.getByTestId("cancel-preview");
	await expect.element(preview).toHaveTextContent("1 paid person deferred");
	await expect
		.element(preview)
		.toHaveTextContent("1 contacted person back on the Waitlist");
	await expect.element(preview).not.toHaveTextContent("Seat Hold");
	await expect
		.element(screen.getByRole("button", { name: "Cancel and email 2" }))
		.toBeVisible();
});

test("ALE-395: a cancelled workshop is read-only, says who and why, and points to Refund Carried Fee", async () => {
	const base = view();
	const deferred = {
		...base.roster.seated[0],
		state: "deferred" as const,
		carriedFee: "held" as const,
		availableCommands: [],
	};
	const returned = {
		...base.roster.asked[0],
		state: "returned" as const,
		availableCommands: [],
	};
	const screen = await render(WorkshopConsole, {
		view: view({
			workshop: { ...base.workshop, status: "cancelled", stage: "cancelled" },
			roster: {
				seated: [],
				asked: [],
				attended: [],
				noShow: [],
				out: [deferred, returned],
			},
			cancellation: {
				at: "2026-10-22T12:00:00Z",
				by: "Clare Coord",
				reason: "Hall flooded",
			},
			fastTrackOpen: false,
		}),
	});

	const now = screen.getByRole("region", { name: "Now" });
	await expect
		.element(now)
		.toHaveTextContent("Cancelled Thu 22 Oct, 13:00 by Clare Coord");
	await expect
		.element(now)
		.toHaveTextContent(
			"1 paid person deferred with a Carried Fee · 1 back on the Waitlist.",
		);
	await expect.element(now).toHaveTextContent("Refund Carried Fee");
	await expect
		.element(screen.getByTestId("cancel-reason"))
		.toHaveTextContent("Hall flooded");
	await expect
		.element(screen.getByRole("button", { name: "Cancel workshop" }))
		.not.toBeInTheDocument();
	await expect
		.element(screen.getByRole("button", { name: /Fast-track/ }))
		.not.toBeInTheDocument();
	await expect
		.element(screen.getByRole("region", { name: "Out of this workshop" }))
		.toHaveTextContent("Deferred");
	await expect
		.element(screen.getByRole("listitem").filter({ hasText: "Cancelled" }))
		.toHaveAttribute("data-state", "done");
});

/** ALE-386: the roster with each Intake's own `availableCommands`. */
function commandsView(): BeginnersWorkshopConsole {
	const base = view();
	return view({
		roster: {
			seated: [
				{
					...base.roster.seated[0],
					medical: true,
					linkGeneration: 2,
					availableCommands: ["resend_link", "rotate_link"],
					paidVia: null,
					carriedFee: null,
					emailLog: [
						{
							emailType: "contact_pay",
							at: "2026-10-20T09:00:00Z",
							scheduled: false,
						},
						{
							emailType: "place_confirmed_paid",
							at: "2026-10-21T18:00:00Z",
							scheduled: false,
						},
						{
							emailType: "pre_workshop",
							at: "2099-11-11T18:30:00Z",
							scheduled: true,
						},
					],
					history: [
						{
							command: "rotate_link",
							actor: "Róisín Walsh",
							occurredAt: "2026-10-22T11:00:00Z",
							note: "Forwarded the email to a friend",
							correction: null,
						},
					],
				},
			],
			asked: [
				{
					...base.roster.asked[0],
					availableCommands: ["decline", "resend_link", "rotate_link"],
					paidVia: null,
					carriedFee: null,
				},
			],
			out: [
				{
					...base.roster.asked[0],
					id: "0b0c3b2e-8a43-4a8d-9a39-5b9d8a2ab003",
					state: "declined",
					firstName: "Eimear",
					lastName: "Ryan",
					availableCommands: [],
					attendanceCorrections: [],
					paidVia: null,
					carriedFee: null,
				},
			],
			attended: [],
			noShow: [],
		},
	});
}

async function openIntake(
	screen: Awaited<ReturnType<typeof render>>,
	name: RegExp,
) {
	await screen.getByRole("button", { name }).click();
	const detail = screen.getByTestId("intake-detail");
	await expect.element(detail).toBeVisible();
	return detail;
}

// Closing the sheet before the test ends lets its exit run; unmounting it
// open reads the console's state after it is gone.
async function closeIntake(screen: Awaited<ReturnType<typeof render>>) {
	await userEvent.keyboard("{Escape}");
	await expect
		.element(screen.getByTestId("intake-detail"))
		.not.toBeInTheDocument();
}

test("ALE-386: a contacted Intake offers exactly Phoenix's availableCommands", async () => {
	const screen = await render(WorkshopConsole, { view: commandsView() });
	const detail = await openIntake(screen, /^Dara Nolan/);

	const buttons = detail.getByTestId("intake-commands").getByRole("button");
	expect(
		buttons.elements().map((button) => button.textContent?.trim()),
	).toEqual(["Decline", "Resend link", "Rotate link"]);
	await expect.element(detail.getByLabelText(/^Note/)).toBeVisible();
	expect(document.body.textContent).not.toMatch(/copy link/i);
	await closeIntake(screen);
});

test("ALE-386: a paid Intake offers no Decline, and shows its flag, link, emails and history", async () => {
	const screen = await render(WorkshopConsole, { view: commandsView() });
	const detail = await openIntake(screen, /^Cian Doyle/);

	const buttons = detail.getByTestId("intake-commands").getByRole("button");
	expect(
		buttons.elements().map((button) => button.textContent?.trim()),
	).toEqual(["Resend link", "Rotate link"]);
	await expect.element(detail.getByTestId("medical-flag")).toBeVisible();
	await expect
		.element(detail.getByTestId("link-generation"))
		.toHaveTextContent("generation 2");

	const emails = detail.getByTestId("email-log").getByRole("listitem");
	expect(emails.elements()).toHaveLength(3);
	await expect.element(emails.nth(0)).toHaveTextContent("Contact — pay");
	await expect
		.element(emails.nth(2))
		.toHaveTextContent("Pre-workshop info (scheduled)");

	await expect
		.element(detail.getByTestId("intake-history"))
		.toHaveTextContent(
			"Link rotated · Róisín Walsh · Thu 22 Oct, 12:00 “Forwarded the email to a friend”",
		);
	await closeIntake(screen);
});

test("ALE-386: a closed Intake offers no commands", async () => {
	const screen = await render(WorkshopConsole, { view: commandsView() });
	const detail = await openIntake(screen, /^Eimear Ryan/);

	await expect
		.element(detail.getByText("No commands for a declined Intake."))
		.toBeVisible();
	expect(detail.getByRole("button").elements()).toHaveLength(0);

	await closeIntake(screen);
});

test("ALE-393: the finalised roster offers the corrections Phoenix allows", async () => {
	const base = view();
	const [seated] = base.roster.seated;
	const [asked] = base.roster.asked;
	const screen = await render(WorkshopConsole, {
		view: view({
			workshop: { ...base.workshop, status: "finalised", stage: "finalised" },
			roster: {
				seated: [],
				asked: [],
				attended: [
					{
						...seated,
						state: "attended",
						availableCommands: ["correct_attendance"],
						attendanceCorrections: ["no_show"],
					},
				],
				noShow: [
					{
						...asked,
						state: "no_show",
						standing: "removed",
						availableCommands: ["correct_attendance"],
						attendanceCorrections: ["attended", "deferred"],
						history: [
							{
								command: "correct_attendance",
								actor: "Clare Coord",
								occurredAt: "2026-11-16T11:00:00Z",
								note: "Door mix-up",
								correction: "no_show",
							},
						],
					},
				],
				out: [],
			},
			fastTrackOpen: false,
			fastTrackHoldersOnly: false,
			finalisation: {
				at: "2026-11-14T20:05:00Z",
				by: "Aoife Coach",
				followUpAt: "2026-11-15T10:00:00Z",
				invitations: { attended: 1, invited: 0, joined: 0 },
			},
		}),
	});

	const noShow = await openIntake(screen, /^Dara Nolan/);
	const buttons = noShow
		.getByTestId("attendance-corrections")
		.getByRole("button");
	expect(
		buttons.elements().map((button) => button.textContent?.trim()),
	).toEqual(["Mark attended", "Defer instead"]);
	expect(noShow.getByTestId("intake-commands").elements()).toHaveLength(0);
	expect(document.body.textContent).not.toMatch(/No commands for/);
	await expect
		.element(noShow.getByTestId("intake-history"))
		.toHaveTextContent(
			"Attendance corrected to no-show · Clare Coord · Mon 16 Nov, 11:00 “Door mix-up”",
		);
	await closeIntake(screen);

	const attended = await openIntake(screen, /^Cian Doyle/);
	expect(
		attended
			.getByTestId("attendance-corrections")
			.getByRole("button")
			.elements()
			.map((button) => button.textContent?.trim()),
	).toEqual(["Mark no-show"]);
	await closeIntake(screen);
});

test("ALE-386: contacted people unpaid after their window need attention", async () => {
	const screen = await render(WorkshopConsole, {
		view: view({
			unpaidAfterWindow: [
				{
					id: "0b0c3b2e-8a43-4a8d-9a39-5b9d8a2ab002",
					firstName: "Dara",
					lastName: "Nolan",
					batchNumber: 1,
					windowEndsAt: "2026-10-27T23:59:59.999999Z",
				},
			],
		}),
	});

	await expect
		.element(
			screen
				.getByRole("region", { name: "Needs attention" })
				.getByTestId("unpaid-after-window"),
		)
		.toHaveTextContent(
			"Dara Nolan hasn't paid — their Batch 1 window ended Tue 27 Oct, 23:59.",
		);
});

/** ALE-387: a Dublin civil date `days` from today. */
function dublinDateIn(days: number): string {
	const today = new Intl.DateTimeFormat("en-CA", {
		timeZone: "Europe/Dublin",
	}).format(new Date());
	const date = new Date(`${today}T00:00:00Z`);
	date.setUTCDate(date.getUTCDate() + days);
	return date.toISOString().slice(0, 10);
}

/** ALE-387: a paid Intake offering Cancel with refund and Withdraw, `days` out. */
function refundView(days: number): BeginnersWorkshopConsole {
	const base = commandsView();
	return {
		...base,
		workshop: { ...base.workshop, date: dublinDateIn(days) },
		roster: {
			...base.roster,
			seated: [
				{
					...base.roster.seated[0],
					availableCommands: [
						"cancel_with_refund",
						"withdraw",
						"resend_link",
						"rotate_link",
					],
					paidVia: null,
					carriedFee: null,
				},
			],
			asked: [
				{
					...base.roster.asked[0],
					availableCommands: [
						"decline",
						"withdraw",
						"resend_link",
						"rotate_link",
					],
					paidVia: null,
					carriedFee: null,
				},
			],
		},
	};
}

test("ALE-387: a paid Intake offers Cancel with refund and Withdraw, with the refund-timing hint 7 days out or closer", async () => {
	const screen = await render(WorkshopConsole, { view: refundView(3) });
	const detail = await openIntake(screen, /^Cian Doyle/);

	const buttons = detail.getByTestId("intake-commands").getByRole("button");
	expect(
		buttons.elements().map((button) => button.textContent?.trim()),
	).toEqual(["Cancel with refund", "Resend link", "Rotate link", "Withdraw…"]);
	await expect
		.element(detail.getByTestId("refund-timing-hint"))
		.toHaveTextContent("Less than 3 days to go");
	await closeIntake(screen);
});

test("ALE-387: no refund-timing hint more than 7 days out, nor on an unpaid Intake", async () => {
	const screen = await render(WorkshopConsole, { view: refundView(8) });
	let detail = await openIntake(screen, /^Cian Doyle/);
	await expect
		.element(detail.getByTestId("refund-timing-hint"))
		.not.toBeInTheDocument();
	await closeIntake(screen);

	screen.rerender({ view: refundView(2) });
	detail = await openIntake(screen, /^Dara Nolan/);
	await expect
		.element(detail.getByTestId("refund-timing-hint"))
		.not.toBeInTheDocument();
	await closeIntake(screen);
});

test("ALE-387: the Withdraw dialog asks to refund or forfeit a paid person's fee", async () => {
	const screen = await render(WorkshopConsole, { view: refundView(7) });
	const detail = await openIntake(screen, /^Cian Doyle/);
	await detail.getByRole("button", { name: "Withdraw…" }).click();

	const dialog = screen.getByRole("dialog", {
		name: "Withdraw Cian Doyle from the Waitlist",
	});
	await expect.element(dialog).toBeVisible();
	await expect
		.element(dialog.getByTestId("refund-timing-hint"))
		.toHaveTextContent("Less than 7 days to go");
	await expect
		.element(dialog.getByRole("radio", { name: /Refund €40\.00/ }))
		.toBeVisible();
	const submit = dialog.getByRole("button", { name: "Withdraw", exact: true });
	await expect.element(submit).toBeDisabled();

	await dialog.getByRole("radio", { name: /Forfeit the fee/ }).click();
	await expect.element(submit).toBeEnabled();

	await dialog.getByRole("button", { name: "Keep them" }).click();
	await expect.element(dialog).not.toBeInTheDocument();
	await closeIntake(screen);
});

test("ALE-387: withdrawing a contacted person asks no money question", async () => {
	const screen = await render(WorkshopConsole, { view: refundView(3) });
	const detail = await openIntake(screen, /^Dara Nolan/);
	await detail.getByRole("button", { name: "Withdraw…" }).click();

	const dialog = screen.getByRole("dialog", {
		name: "Withdraw Dara Nolan from the Waitlist",
	});
	await expect
		.element(dialog)
		.toHaveTextContent("their Intake closes as declined");
	expect(dialog.getByRole("radio").elements()).toHaveLength(0);
	await expect
		.element(dialog.getByRole("button", { name: "Withdraw", exact: true }))
		.toBeEnabled();
	await dialog.getByRole("button", { name: "Keep them" }).click();
	await closeIntake(screen);
});

test("ALE-388: Carried Fee holders are marked confirms, show their fee, and need attention until they confirm", async () => {
	const base = view();
	const holder = {
		...base.roster.asked[0]!,
		carriedFee: "held" as const,
		availableCommands: [
			"decline",
			"confirm",
			"resend_link",
			"rotate_link",
		] as const satisfies BeginnersWorkshopConsole["roster"]["asked"][number]["availableCommands"],
		history: [
			{
				command: "confirm" as const,
				actor: null,
				occurredAt: "2026-10-22T11:00:00Z",
				note: null,
				correction: null,
			},
		],
	};
	const screen = await render(WorkshopConsole, {
		view: view({
			nextBatch: {
				...base.nextBatch,
				people: [
					{ ...base.nextBatch.people[0]!, confirms: true },
					base.nextBatch.people[1]!,
				],
			},
			roster: {
				...base.roster,
				seated: [
					{
						...base.roster.seated[0]!,
						paidVia: "carried_fee",
						carriedFee: "applied",
						availableCommands: ["defer", "resend_link", "rotate_link"],
					},
				],
				asked: [
					{ ...holder, availableCommands: [...holder.availableCommands] },
				],
			},
			unconfirmedCarriedFees: [
				{
					id: holder.id,
					firstName: "Dara",
					lastName: "Nolan",
					batchNumber: 1,
					contactedAt: "2026-10-20T09:00:00Z",
				},
			],
		}),
	});

	const proposed = screen.getByRole("list", { name: "Proposed people" });
	expect(proposed.getByTestId("confirms").elements()).toHaveLength(1);
	await expect
		.element(proposed.getByRole("listitem").nth(0))
		.toHaveTextContent("confirms");

	await expect
		.element(
			screen
				.getByRole("region", { name: "Needs attention" })
				.getByTestId("unconfirmed-carried-fee"),
		)
		.toHaveTextContent("Dara Nolan holds a Carried Fee and hasn't confirmed");

	await expect
		.element(screen.getByRole("button", { name: /^Cian Doyle/ }))
		.toHaveTextContent("Carried Fee · applied");

	const detail = await openIntake(screen, /^Dara Nolan — Contacted/);
	await expect
		.element(detail.getByTestId("carried-fee"))
		.toHaveTextContent("Carried Fee · held");
	expect(
		detail
			.getByTestId("intake-commands")
			.getByRole("button")
			.elements()
			.map((button) => button.textContent?.trim()),
	).toEqual([
		"Decline",
		"Confirm with Carried Fee",
		"Resend link",
		"Rotate link",
	]);
	await expect
		.element(detail.getByTestId("intake-history"))
		.toHaveTextContent("Confirmed with Carried Fee · by the person");
	await closeIntake(screen);
});
