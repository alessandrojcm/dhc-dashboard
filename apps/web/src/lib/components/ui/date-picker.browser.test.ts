import {
	CalendarDate,
	resetLocalTimeZone,
	setLocalTimeZone,
} from "@internationalized/date";
import { expect, test, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import DatePicker from "./date-picker.svelte";

test("selects a date from the calendar popover", async () => {
	const onDateChange = vi.fn<(date: Date) => void>();
	const screen = await render(DatePicker, {
		value: new CalendarDate(2000, 1, 1),
		onDateChange,
		label: "Date of birth",
		type: "date",
	});

	const trigger = screen.getByRole("button", { name: "Date of birth" });
	await expect.element(trigger).toHaveAttribute("type", "button");
	await userEvent.click(trigger);
	await screen.getByLabelText("Select a year").selectOptions("2001");
	await screen.getByLabelText("Select a month").selectOptions("2");
	await userEvent.click(
		screen.getByRole("button", { name: "Thursday, February 15," }),
	);

	expect(onDateChange).toHaveBeenCalledOnce();
	const selectedDate = onDateChange.mock.calls[0][0];
	expect(selectedDate.getFullYear()).toBe(2001);
	expect(selectedDate.getMonth()).toBe(1);
	expect(selectedDate.getDate()).toBe(15);
});

test("opens the calendar popover without an initial date", async () => {
	const screen = await render(DatePicker, {
		value: undefined,
		onDateChange: vi.fn(),
		name: "dateOfBirth",
		id: "dateOfBirth",
		type: "date",
	});

	await userEvent.click(screen.getByRole("button", { name: "Select a date" }));

	await expect.element(screen.getByLabelText("Select a year")).toBeVisible();
});

test("keeps the selected date when it is clicked again", async () => {
	const onValueChange = vi.fn();
	const screen = await render(DatePicker, {
		value: new CalendarDate(2000, 1, 1),
		onValueChange,
		label: "Due",
	});

	await userEvent.click(screen.getByRole("button", { name: "Due" }));
	await userEvent.click(
		screen.getByRole("button", { name: "Saturday, January 1," }),
	);

	await expect
		.element(screen.getByRole("button", { name: "Due" }))
		.toHaveTextContent("January 1, 2000");
	expect(onValueChange).not.toHaveBeenCalledWith(undefined);
});

test("submits a date-only value without timezone conversion", async () => {
	setLocalTimeZone("Europe/Dublin");

	try {
		const screen = await render(DatePicker, {
			value: new CalendarDate(2001, 4, 15),
			onDateChange: vi.fn(),
			name: "dateOfBirth",
		});

		const hiddenInput = screen.container.querySelector<HTMLInputElement>(
			'input[type="hidden"][name="dateOfBirth"]',
		);
		expect(hiddenInput?.value).toBe("2001-04-15");
	} finally {
		resetLocalTimeZone();
	}
});
