import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import {
	FakeVenueLookup,
	venueLookupContext,
} from "#lib/testing/fake-venue-lookup.js";
import ScheduleWorkshopsDialog from "./schedule-workshops-dialog.svelte";

// ALE-442: the venue lookup boundary, substituted with a synthetic place.
const lookup = new FakeVenueLookup([
	{
		provider: "google",
		placeId: "place_hall",
		name: "Synthetic Fencing Hall",
		address: "1 Example Street, Dublin 8",
		attributions: [{ provider: "Venue Guide", providerUri: null }],
	},
]);

// The remote form strips its `/<form id>` suffix from control names, so a
// name check compares the field part only.
function fieldNames(form: HTMLFormElement) {
	return [...form.elements]
		.map((element) => element.getAttribute("name"))
		.filter((name): name is string => !!name)
		.map((name) => name.split("/")[0]);
}

function formElement(element: Element): HTMLFormElement {
	if (!(element instanceof HTMLFormElement)) throw new Error("not a form");
	return element;
}

async function openDialog() {
	const screen = await render(ScheduleWorkshopsDialog, {
		context: venueLookupContext(lookup),
		props: { open: true },
	});
	const form = screen.getByRole("form", {
		name: "Schedule Beginners' Workshops",
	});
	await expect.element(form).toBeVisible();
	return { screen, form };
}

// The remote form is one module-level instance, so its field values carry
// over between tests: the validation test runs before any date is picked.
test("refuses to submit until the venue, end time and a date are given", async () => {
	const { screen } = await openDialog();

	await userEvent.click(
		screen.getByRole("button", { name: "Schedule workshop" }),
	);

	await expect.element(screen.getByText("Enter the venue.")).toBeVisible();
	await expect.element(screen.getByText("Enter the end time.")).toBeVisible();
	await expect
		.element(screen.getByText("Pick the workshop date."))
		.toBeVisible();
	await expect
		.element(
			screen.getByRole("form", { name: "Schedule Beginners' Workshops" }),
		)
		.toBeVisible();
});

test("prefills the shared values and names every control from its field", async () => {
	const { screen, form } = await openDialog();

	await expect.element(screen.getByLabelText("Capacity")).toHaveValue(16);
	await expect.element(screen.getByLabelText("Fee (€)")).toHaveValue(40);
	await expect
		.element(screen.getByLabelText("Reply period (days)"))
		.toHaveValue(7);
	await expect
		.element(screen.getByLabelText("Start time"))
		.toHaveValue("18:30");
	await expect.element(screen.getByLabelText("End time")).toHaveValue("");

	expect(fieldNames(formElement(form.element()))).toEqual(
		expect.arrayContaining([
			"venue",
			"startTime",
			"endTime",
			"n:capacity",
			"n:fee",
			"n:paymentWindowDays",
			"workshops[0].date",
			"workshops[0].paymentCutoffDate",
			"workshops[0].contactFromDate",
		]),
	);
});

test("adds and removes dates, one workshop per date", async () => {
	const { screen } = await openDialog();
	const rows = screen.getByTestId("schedule-date-row");

	await expect
		.element(screen.getByRole("button", { name: "Remove date 1" }))
		.toBeDisabled();
	await userEvent.click(
		screen.getByRole("button", { name: "Add another date" }),
	);
	await userEvent.click(
		screen.getByRole("button", { name: "Add another date" }),
	);

	expect(rows.elements()).toHaveLength(3);
	await expect
		.element(screen.getByRole("button", { name: "Schedule 3 workshops" }))
		.toBeVisible();

	await userEvent.click(screen.getByRole("button", { name: "Remove date 2" }));
	expect(rows.elements()).toHaveLength(2);
	await expect
		.element(screen.getByRole("button", { name: "Schedule 2 workshops" }))
		.toBeVisible();
});

test("a picked date is submitted as a civil YYYY-MM-DD value", async () => {
	const { screen, form } = await openDialog();

	await userEvent.click(
		screen.getByRole("button", { name: "Workshop date 1" }),
	);
	await screen.getByLabelText("Select a year").selectOptions("2027");
	await screen.getByLabelText("Select a month").selectOptions("1");
	await userEvent.click(
		screen.getByRole("button", { name: "Saturday, January 16," }),
	);

	const hidden = formElement(form.element()).querySelector<HTMLInputElement>(
		'input[type="hidden"][name^="workshops[0].date"]',
	);
	expect(hidden?.value).toBe("2027-01-16");
	await expect
		.element(screen.getByRole("button", { name: "Workshop date 1" }))
		.toHaveTextContent("January 16, 2027");
});

test("offers optional Staff shared by every date (ALE-379)", async () => {
	const coach = "0f3f9d0c-3b52-4a4f-9a51-6a3f1b2a2f10";
	const screen = await render(ScheduleWorkshopsDialog, {
		open: true,
		candidates: [{ principalId: coach, name: "Aoife Coach", coach: true }],
	});
	const form = screen.getByRole("form", {
		name: "Schedule Beginners' Workshops",
	});
	await expect
		.element(screen.getByRole("combobox", { name: "Coach" }))
		.toHaveTextContent("No coach assigned");
	expect(fieldNames(formElement(form.element()))).not.toContain(
		"coachPrincipalId",
	);

	await userEvent.click(screen.getByRole("combobox", { name: "Coach" }));
	await userEvent.click(screen.getByRole("option", { name: /Aoife Coach/ }));

	expect(fieldNames(formElement(form.element()))).toContain("coachPrincipalId");
});

test("ALE-442: a chosen Google place is shared by every date through its hidden Place ID only", async () => {
	const { screen, form } = await openDialog();

	const destination = screen.getByRole("combobox", { name: "Destination" });
	await userEvent.click(destination);
	await userEvent.keyboard("Synthetic");
	await screen.getByRole("option", { name: /Synthetic Fencing Hall/ }).click();

	await expect
		.element(destination)
		.toHaveValue(expect.stringContaining("Synthetic Fencing Hall"));
	await expect
		.element(screen.getByTestId("destination-attribution"))
		.toHaveTextContent("Google Maps · Venue Guide");
	// The short email-sized venue label stays the coordinator's own.
	await expect.element(screen.getByLabelText("Venue")).toHaveValue("");
	// Choosing a place never submits the dialog.
	await expect.element(form).toBeVisible();

	const element = formElement(form.element());
	expect(fieldNames(element)).toEqual(
		expect.arrayContaining(["destination_text", "destination_place_id"]),
	);
	expect(fieldNames(element)).not.toContain("destination_attributions");
	const value = (name: string) =>
		[...element.elements]
			.filter(
				(control): control is HTMLInputElement =>
					control instanceof HTMLInputElement,
			)
			.find((control) => control.name.split("/")[0] === name)?.value;
	expect(value("destination_place_id")).toBe("place_hall");
	// Google's text is shown in the input only: none of it is submitted.
	expect(value("destination_text")).toBe("");
});
