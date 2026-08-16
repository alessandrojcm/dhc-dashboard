import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import Calendar25 from "./calendar-25.svelte";

test("opens the calendar popover after mounting", async () => {
	const screen = await render(Calendar25, { id: "workshop" });

	await expect
		.element(screen.getByTestId("workshop-date-time-picker"))
		.toHaveAttribute("data-hydrated", "true");
	await userEvent.click(screen.getByRole("button", { name: "Date" }));

	await expect.element(screen.getByLabelText("Select a year")).toBeVisible();
	await expect.element(screen.getByLabelText("Select a month")).toBeVisible();
});
