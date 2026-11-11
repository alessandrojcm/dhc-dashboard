import type { BeginnersWorkshop } from "@dhc/api-client";
import { expect, test } from "vitest";
import { page, userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import {
	FakeVenueLookup,
	venueLookupContext,
} from "#lib/testing/fake-venue-lookup.js";
import RescheduleDialog from "./reschedule-dialog.svelte";

// ALE-442: the one venue lookup boundary, substituted with a synthetic place.
const lookup = new FakeVenueLookup([
	{
		provider: "google",
		placeId: "place_annex",
		name: "Synthetic Fencing Annex",
		address: "2 Example Street, Dublin 8",
		attributions: [],
	},
]);

let nextWorkshopId = 1;

function uniqueWorkshopId() {
	return `6d9e6110-fc8c-4dcf-b64f-${String(nextWorkshopId++).padStart(12, "0")}`;
}

function workshop(
	overrides: Partial<BeginnersWorkshop> = {},
): BeginnersWorkshop {
	return {
		id: uniqueWorkshopId(),
		status: "scheduled",
		venue: "St. Andrew's Hall",
		destinationName: null,
		destinationAddress: null,
		directionsUrl: null,
		destinationProvider: null,
		destinationPlaceId: null,
		date: "2026-11-14",
		startTime: "18:30",
		endTime: "20:30",
		capacity: 16,
		feeCents: 4000,
		paymentCutoff: "2026-11-11T18:30:00Z",
		paymentCutoffDate: "2026-11-11",
		paymentCutoffTime: "18:30",
		contactFromDate: "2026-10-20",
		contactFromEditable: false,
		paymentWindowDays: 7,
		stage: "window_open",
		seats: {
			capacity: 16,
			paid: 1,
			holds: 0,
			free: 15,
			attended: 0,
			noShow: 0,
		},
		alerts: [],
		staff: { coach: null, assistants: [] },
		...overrides,
	};
}

async function openDialog(
	recipients: number,
	overrides: Partial<BeginnersWorkshop> = {},
) {
	const screen = await render(RescheduleDialog, {
		context: venueLookupContext(lookup),
		props: {
			workshop: workshop(overrides),
			recipients,
			open: true,
			today: "2026-10-09",
		},
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
		.element(screen.getByLabelText("Payment deadline time"))
		.toHaveValue("18:30");

	await userEvent.fill(screen.getByLabelText("Start"), "19:15");
	await expect
		.element(screen.getByLabelText("Payment deadline time"))
		.toHaveValue("19:15");

	// After Batch 1 the contact-from date can't change, so it isn't offered.
	await expect
		.element(screen.getByText("Start offering places", { exact: true }))
		.not.toBeInTheDocument();
});

test("requires both times and rejects an end time equal to the start", async () => {
	const { screen } = await openDialog(0);

	await expect.element(screen.getByLabelText("End time")).toHaveValue("20:30");
	await userEvent.fill(screen.getByLabelText("End time"), "18:30");
	await userEvent.click(
		screen.getByRole("button", { name: "Reschedule", exact: true }),
	);

	await expect
		.element(screen.getByText("End time must be after start time."))
		.toBeVisible();
});

test("offers the contact-from date while Batch 1 hasn't gone out", async () => {
	const { screen } = await openDialog(0, {
		contactFromEditable: true,
		stage: "before_contact_from",
	});

	await expect
		.element(screen.getByTestId("reschedule-warning"))
		.toHaveTextContent(
			"No emails will be sent: nobody has an active workshop place.",
		);
	await expect
		.element(
			screen.getByText(
				"Automatic offers can start from 10:00 on this date, subject to available places and pauses.",
			),
		)
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Reschedule", exact: true }))
		.toBeVisible();
});

test("ALE-441: a destination-only edit saves without emailing; a move is still a reschedule", async () => {
	const { screen, form } = await openDialog(3, {
		destinationName: "National Basketball Arena",
		destinationAddress: null,
		directionsUrl: null,
		destinationProvider: null,
		destinationPlaceId: null,
	});
	const operation = () =>
		form
			.element()
			.querySelector<HTMLInputElement>('input[type=hidden][name*="operation"]')
			?.value;

	await expect
		.element(screen.getByLabelText("Destination name"))
		.toHaveValue("National Basketball Arena");
	// Nothing changed yet: the dialog is a reschedule.
	expect(operation()).toBe("reschedule");

	await userEvent.fill(
		screen.getByLabelText("Destination address"),
		"Tymon Park, Dublin 6w",
	);
	await expect
		.element(screen.getByTestId("reschedule-warning"))
		.toHaveTextContent(
			"No emails will be sent: only the destination details change.",
		);
	await expect
		.element(screen.getByRole("button", { name: "Save destination" }))
		.toBeVisible();
	expect(operation()).toBe("destination");

	await userEvent.fill(screen.getByLabelText("Venue"), "The Hub");
	await expect
		.element(screen.getByRole("button", { name: "Reschedule and email 3" }))
		.toBeVisible();
	expect(operation()).toBe("reschedule");
});

test("ALE-441: the destination link gets the shared https check before submitting", async () => {
	const { screen } = await openDialog(0);

	await userEvent.fill(
		screen.getByLabelText("Google Maps directions link"),
		"http://maps.google.com/?q=Tallaght",
	);
	await userEvent.click(
		screen.getByRole("button", { name: "Save destination" }),
	);

	await expect
		.element(screen.getByText("Directions link must be an https link"))
		.toBeVisible();
});

test("ALE-442: replacing a saved Google place is a destination-only change, and Escape keeps the dialog open", async () => {
	const { screen, form } = await openDialog(3, {
		destinationName: "Our hall",
		destinationAddress: null,
		destinationProvider: "google",
		destinationPlaceId: "place_hall",
	});
	const hidden = (name: string) =>
		form
			.element()
			.querySelector<HTMLInputElement>(`input[type=hidden][name*="${name}"]`)
			?.value;

	// A saved place has no stored Google text: it reopens as "selected" only,
	// beside the staff-typed name.
	const preview = screen.getByRole("region", { name: "Selected place" });
	await expect.element(preview).toHaveTextContent("Google Maps place selected");
	expect(
		preview.getByTestId("destination-attribution").elements(),
	).toHaveLength(0);
	await expect
		.element(screen.getByRole("textbox", { name: "Destination name" }))
		.toHaveValue("Our hall");
	expect(hidden("operation")).toBe("reschedule");

	await userEvent.click(
		screen.getByRole("combobox", { name: "Replace with another place" }),
	);
	await userEvent.keyboard("Annex");
	await expect.element(screen.getByRole("option").first()).toBeVisible();
	await userEvent.keyboard("{Escape}");
	await expect
		.element(screen.getByRole("option").first())
		.not.toBeInTheDocument();
	await expect.element(form).toBeVisible();

	await userEvent.keyboard("{Backspace}");
	await screen.getByRole("option", { name: /Annex/ }).click();
	// Google's preview of the new place, for this session only; the staff
	// text is untouched.
	await expect.element(preview).toHaveTextContent("Synthetic Fencing Annex");
	await expect
		.element(preview.getByTestId("destination-attribution"))
		.toHaveTextContent("Google Maps");
	await expect
		.element(screen.getByRole("textbox", { name: "Destination name" }))
		.toHaveValue("Our hall");
	expect(lookup.resolveCalls.map((call) => call.placeId)).toEqual([
		"place_annex",
	]);

	await expect
		.element(screen.getByRole("button", { name: "Save destination" }))
		.toBeVisible();
	expect(hidden("operation")).toBe("destination");
	expect(hidden("destination_place_id")).toBe("place_annex");
	expect(
		form.element().querySelector('[name*="destination_attributions"]'),
	).toBeNull();
});

test("ALE-442: the search and a selected place fit a phone", async () => {
	await page.viewport(375, 740);
	const { screen } = await openDialog(0, {
		destinationName: "Our hall with a fairly long staff-typed name",
		destinationAddress: "1 Example Street, Dublin 8, D08 X000, Ireland",
		destinationProvider: "google",
		destinationPlaceId: "place_hall",
	});

	const preview = screen
		.getByRole("region", { name: "Selected place" })
		.element();
	const remove = screen.getByRole("button", { name: "Remove place" }).element();
	const search = screen
		.getByRole("combobox", { name: "Replace with another place" })
		.element();
	for (const element of [preview, remove, search]) {
		const box = element.getBoundingClientRect();
		expect(box.left).toBeGreaterThanOrEqual(0);
		expect(box.right).toBeLessThanOrEqual(375);
	}
	// Touch-sized controls.
	expect(remove.getBoundingClientRect().height).toBeGreaterThanOrEqual(44);
	expect(search.getBoundingClientRect().height).toBeGreaterThanOrEqual(44);
});
