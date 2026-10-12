import "../../../app.css";
import { afterEach, expect, test } from "vitest";
import { page, userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import WorkshopDialogTest from "./workshop-dialog.test-wrapper.svelte";

afterEach(async () => {
	document.documentElement.classList.remove("dark");
	await page.viewport(1280, 900);
});

function contrast(first: string, second: string) {
	const luminance = (color: string) => {
		const channels = color
			.match(/[\d.]+/g)!
			.slice(0, 3)
			.map(Number)
			.map((value) => {
				const channel = value / 255;
				return channel <= 0.04045
					? channel / 12.92
					: ((channel + 0.055) / 1.055) ** 2.4;
			});
		return (
			channels[0]! * 0.2126 + channels[1]! * 0.7152 + channels[2]! * 0.0722
		);
	};
	const a = luminance(first);
	const b = luminance(second);
	return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

for (const dark of [false, true]) {
	for (const viewport of [
		{ width: 390, height: 844 },
		{ width: 844, height: 390 },
	]) {
		test(`long forms keep headers and actions visible at ${viewport.width}×${viewport.height} in ${dark ? "dark" : "light"} mode`, async () => {
			await page.viewport(viewport.width, viewport.height);
			document.documentElement.classList.toggle("dark", dark);
			const screen = await render(WorkshopDialogTest);
			const reference = screen
				.getByRole("textbox", { name: "Reference input" })
				.element();
			await screen.getByRole("button", { name: "Open workshop form" }).click();
			const dialog = screen.getByRole("dialog");
			await expect.element(dialog).toBeVisible();
			await expect
				.element(screen.getByRole("textbox", { name: "Detail 1", exact: true }))
				.toHaveFocus();
			const element = dialog.element();
			const form = element.querySelector("form")!;
			const header = element.querySelector('[data-slot="dialog-header"]')!;
			const footer = element.querySelector('[data-slot="dialog-footer"]')!;
			const save = screen
				.getByRole("button", { name: "Save details" })
				.element();
			await expect
				.poll(() => save.getBoundingClientRect().height)
				.toBeGreaterThanOrEqual(44);
			await expect
				.poll(() => element.getBoundingClientRect().top)
				.toBeGreaterThanOrEqual(0);
			const box = element.getBoundingClientRect();
			expect(box.right).toBeLessThanOrEqual(viewport.width);
			expect(box.bottom).toBeLessThanOrEqual(viewport.height);
			expect(form.scrollHeight).toBeGreaterThan(form.clientHeight);
			const headerTop = header.getBoundingClientRect().top;
			form.scrollTop = form.scrollHeight;
			expect(header.getBoundingClientRect().top).toBe(headerTop);
			expect(footer.getBoundingClientRect().bottom).toBeLessThanOrEqual(
				box.bottom,
			);
			const surface = getComputedStyle(element);
			const input = screen
				.getByRole("textbox", { name: "Detail 1", exact: true })
				.element();
			for (const pseudo of [null, "::placeholder"]) {
				const actual = getComputedStyle(input, pseudo);
				const expected = getComputedStyle(reference, pseudo);
				expect(actual.fontSize).toBe(expected.fontSize);
				expect(actual.color).toBe(expected.color);
				expect(actual.backgroundColor).toBe(expected.backgroundColor);
				expect(actual.opacity).toBe(expected.opacity);
			}
			const description = getComputedStyle(
				element.querySelector('[data-slot="dialog-description"]')!,
			);
			expect(
				contrast(description.color, surface.backgroundColor),
			).toBeGreaterThanOrEqual(4.5);
			await userEvent.keyboard("{Escape}");
			await expect
				.element(screen.getByRole("button", { name: "Open workshop form" }))
				.toHaveFocus();
		});
	}
}

test("waitlist alerts retain alert semantics and cancellation focus", async () => {
	const screen = await render(WorkshopDialogTest, { alert: true });
	await screen.getByRole("button", { name: "Change waitlist" }).click();
	await expect.element(screen.getByRole("alertdialog")).toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Keep open" }))
		.toHaveFocus();
	await screen.getByRole("button", { name: "Keep open" }).click();
	await expect
		.element(screen.getByRole("button", { name: "Change waitlist" }))
		.toHaveFocus();
});
