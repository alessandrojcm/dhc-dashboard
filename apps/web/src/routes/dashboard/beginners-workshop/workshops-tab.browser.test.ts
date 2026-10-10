import type { BeginnersWorkshop } from "@dhc/api-client";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import WorkshopsTab from "./workshops-tab.svelte";

function workshop(overrides: Partial<BeginnersWorkshop>): BeginnersWorkshop {
	return {
		id: "6d9e6110-fc8c-4dcf-b64f-db21b20d5140",
		status: "scheduled",
		venue: "St. Andrew's Hall",
		date: "2026-11-14",
		startTime: "18:30",
		capacity: 16,
		feeCents: 4000,
		paymentCutoff: "2026-11-11T18:30:00Z",
		paymentCutoffDate: "2026-11-11",
		paymentCutoffTime: "18:30",
		contactFromDate: "2026-10-09",
		contactFromEditable: true,
		paymentWindowDays: 7,
		stage: "next_batch_due",
		seats: {
			capacity: 16,
			paid: 3,
			holds: 1,
			free: 12,
			attended: 0,
			noShow: 0,
		},
		alerts: ["unstaffed"],
		staff: { coach: null, assistants: [] },
		...overrides,
	};
}

test("shows Phoenix's stage, seat meter and alerts, upcoming before past", async () => {
	const screen = await render(WorkshopsTab, {
		candidates: [],
		workshops: {
			upcoming: [workshop({})],
			past: [
				workshop({
					id: "b7f1c9a3-b377-4f9b-8661-b296964bf237",
					status: "cancelled",
					stage: "cancelled",
					alerts: [],
					staff: {
						coach: {
							principalId: "0f3f9d0c-3b52-4a4f-9a51-6a3f1b2a2f10",
							name: "Aoife Coach",
						},
						assistants: [
							{
								principalId: "5a3c7c8e-2f1b-4c55-8d0b-1a6f0f7e9b21",
								name: "Brian Assist",
							},
						],
					},
				}),
			],
		},
	});

	const rows = screen.getByTestId("beginners-workshop-row");
	expect(rows.elements()).toHaveLength(2);
	await expect.element(rows.nth(0)).toHaveTextContent("Next Batch due");
	await expect
		.element(rows.nth(0))
		.toHaveTextContent("Unstaffed: no Staff assigned");
	await expect
		.element(rows.nth(0).getByTestId("seat-meter"))
		.toHaveTextContent("3 paid · 1 paying now · 12 free of 16");
	await expect.element(rows.nth(0)).toHaveTextContent("€40.00");
	await expect.element(rows.nth(0)).toHaveTextContent("No Staff yet");
	await expect.element(rows.nth(1)).toHaveTextContent("Cancelled");
	await expect
		.element(rows.nth(1))
		.toHaveTextContent("Aoife Coach (coach), Brian Assist");
	// Staff can change only on a scheduled workshop; both open the door view.
	expect(
		screen.getByRole("button", { name: /^Staff for/ }).elements(),
	).toHaveLength(1);
	expect(
		screen.getByRole("link", { name: /^Door view for/ }).elements(),
	).toHaveLength(2);
	await expect
		.element(
			screen.getByRole("button", {
				name: "Capacity, fee and cutoff for 2026-11-14",
			}),
		)
		.toBeVisible();
	expect(
		screen.getByRole("button", { name: /Capacity, fee and cutoff/ }).elements(),
	).toHaveLength(1);
});

test("an empty list invites the coordinator to schedule", async () => {
	const screen = await render(WorkshopsTab, {
		candidates: [],
		workshops: { upcoming: [], past: [] },
	});
	await expect.element(screen.getByText("No upcoming workshops")).toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Schedule workshops" }))
		.toBeVisible();
});
