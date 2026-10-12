import type {
	BeginnersWorkshop,
	BeginnersWorkshopConsoleCancelPreview,
} from "@dhc/api-client";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import CancelWorkshopDialog from "./cancel-workshop-dialog.svelte";

const workshop: BeginnersWorkshop = {
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
	seats: { capacity: 16, paid: 3, holds: 1, free: 12, attended: 0, noShow: 0 },
	alerts: [],
	staff: { coach: null, assistants: [] },
};

async function openDialog(preview: BeginnersWorkshopConsoleCancelPreview) {
	const screen = await render(CancelWorkshopDialog, {
		workshop,
		preview,
		open: true,
	});
	const form = screen.getByRole("form", { name: "Cancel workshop" });
	await expect.element(form).toBeVisible();
	return screen;
}

test("shows the deferred, returned and released counts", async () => {
	const screen = await openDialog({ deferred: 3, returned: 2, released: 1 });
	const preview = screen.getByTestId("cancel-preview");

	await expect
		.element(preview)
		.toHaveTextContent(
			"3 paid people will receive credit for a later workshop",
		);
	await expect
		.element(preview)
		.toHaveTextContent("2 people offered a place will return to the waitlist");
	await expect
		.element(preview)
		.toHaveTextContent("1 place reserved during checkout will be released");
	await expect
		.element(screen.getByRole("button", { name: "Cancel and email 5" }))
		.toBeVisible();
	await expect
		.element(
			screen.getByLabelText(
				"Reason (optional, saved with each person's workshop record)",
			),
		)
		.toBeVisible();
});

test("an empty workshop emails nobody and releases nothing", async () => {
	const screen = await openDialog({ deferred: 0, returned: 0, released: 0 });
	const preview = screen.getByTestId("cancel-preview");

	await expect
		.element(preview)
		.toHaveTextContent(
			"0 paid people will receive credit for a later workshop",
		);
	await expect
		.element(preview)
		.not.toHaveTextContent("reserved during checkout");
	await expect
		.element(screen.getByRole("button", { name: "Cancel workshop" }))
		.toBeVisible();
});
