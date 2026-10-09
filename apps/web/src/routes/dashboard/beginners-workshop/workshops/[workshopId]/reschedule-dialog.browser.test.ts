import type { BeginnersWorkshop } from "@dhc/api-client";
import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import RescheduleDialog from "./reschedule-dialog.svelte";

function workshop(
	overrides: Partial<BeginnersWorkshop> = {},
): BeginnersWorkshop {
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
		contactFromDate: "2026-10-20",
		contactFromEditable: false,
		paymentWindowDays: 7,
		stage: "window_open",
		seats: { capacity: 16, paid: 1, holds: 0, free: 15 },
		alerts: [],
		staff: { coach: null, assistants: [] },
		...overrides,
	};
}

async function openDialog(recipients: number, overrides = {}) {
	const screen = await render(RescheduleDialog, {
		workshop: workshop(overrides),
		recipients,
		open: true,
		today: "2026-10-09",
	});
	const form = screen.getByRole("form", { name: "Reschedule workshop" });
	await expect.element(form).toBeVisible();
	return { screen, form };
}

test("warns how many people the reschedule emails before saving", async () => {
	const { screen } = await openDialog(3);

	await expect
		.element(screen.getByTestId("reschedule-warning"))
		.toHaveTextContent("This emails 3 people “Workshop rescheduled”.");
	await expect
		.element(screen.getByRole("button", { name: "Reschedule and email 3" }))
		.toBeVisible();
});

test("prefills the kept cutoff and follows a new start time", async () => {
	const { screen } = await openDialog(1);

	await expect
		.element(screen.getByTestId("reschedule-warning"))
		.toHaveTextContent("This emails 1 person");
	await expect
		.element(screen.getByLabelText("Cutoff time"))
		.toHaveValue("18:30");

	await userEvent.fill(screen.getByLabelText("Start"), "19:15");
	await expect
		.element(screen.getByLabelText("Cutoff time"))
		.toHaveValue("19:15");

	// After Batch 1 the contact-from date can't change, so it isn't offered.
	await expect
		.element(screen.getByText("Contact from", { exact: true }))
		.not.toBeInTheDocument();
});

test("offers the contact-from date while Batch 1 hasn't gone out", async () => {
	const { screen } = await openDialog(0, {
		contactFromEditable: true,
		stage: "before_contact_from",
	});

	await expect
		.element(screen.getByTestId("reschedule-warning"))
		.toHaveTextContent("nobody is emailed");
	await expect
		.element(screen.getByText("Batch 1 goes out at 10:00 on this date."))
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Reschedule", exact: true }))
		.toBeVisible();
});
