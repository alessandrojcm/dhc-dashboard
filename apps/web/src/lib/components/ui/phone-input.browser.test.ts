import { expect, test, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import PhoneInput from "./phone-input.svelte";

test("formats Irish national input while emitting its E.164 value", async () => {
	const onChange = vi.fn();
	const screen = await render(PhoneInput, {
		id: "phone-number",
		onChange,
	});
	const input = screen.getByRole("textbox");

	await userEvent.type(input, "0838774532");

	await expect.element(input).toHaveValue("083 877 4532");
	expect(onChange).toHaveBeenLastCalledWith("+353838774532");
	expect(
		(document.querySelector('input[type="hidden"]') as HTMLInputElement).value,
	).toBe("+353838774532");
});

test("displays an E.164 value in national format", async () => {
	const screen = await render(PhoneInput, {
		id: "phone-number",
		value: "+353838774532",
	});

	await expect.element(screen.getByRole("textbox")).toHaveValue("083 877 4532");
});
