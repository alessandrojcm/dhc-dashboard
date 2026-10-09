import type { BeginnersIntakePage } from "@dhc/api-client";
import { expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import { INACTIVE_PAGE } from "#lib/beginners-workshops/intake-page.js";
import IntakePage from "./intake-page.svelte";

const token = "intake-link-token";

function page(
	overrides: Partial<BeginnersIntakePage> = {},
): BeginnersIntakePage {
	return {
		state: "pay",
		action: "pay",
		closedReason: null,
		firstName: "Aoife",
		workshop: {
			date: "2026-11-14",
			startTime: "18:30",
			venue: "St. Andrew's Hall",
		},
		feeCents: 4000,
		...overrides,
	};
}

test("pay: the person's name, the workshop, the fee and one Pay button", async () => {
	const screen = await render(IntakePage, { page: page(), token });

	await expect.element(screen.getByText("Hi Aoife,")).toBeVisible();
	const workshop = screen.getByRole("list", { name: "Workshop" });
	await expect.element(workshop).toHaveTextContent("Sat 14 Nov 2026");
	await expect.element(workshop).toHaveTextContent("18:30");
	await expect.element(workshop).toHaveTextContent("St. Andrew's Hall");
	await expect.element(screen.getByText("€40.00")).toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Pay for your place" }))
		.toBeEnabled();
	expect(screen.getByRole("button").elements()).toHaveLength(1);
	// ALE-386 (story 54): no self-service decline or withdraw — every exit
	// goes through a coordinator, by replying to the email.
	for (const role of ["button", "link"] as const)
		expect(
			screen.getByRole(role, { name: /decline|withdraw/i }).elements(),
		).toHaveLength(0);
	expect(
		document.querySelector("input[type=hidden]")?.getAttribute("value"),
	).toBe(token);
});

test("pay with a live hold continues the same checkout", async () => {
	const screen = await render(IntakePage, {
		page: page({ action: "continue_payment" }),
		token,
	});

	await expect
		.element(screen.getByRole("button", { name: "Continue to payment" }))
		.toBeVisible();
});

test("payment_in_progress refreshes on its own until Phoenix reports paid", async () => {
	const refresh = vi.fn();
	const screen = await render(IntakePage, {
		page: page({ state: "payment_in_progress", action: "check_again" }),
		token,
		refresh,
		refreshMs: 20,
	});

	await expect
		.element(screen.getByRole("heading", { name: "Payment in progress" }))
		.toBeVisible();
	await expect.element(screen.getByText(/no need to pay again/)).toBeVisible();
	await vi.waitFor(() => expect(refresh).toHaveBeenCalled());
	expect(screen.getByRole("button", { name: /Pay/ }).elements()).toHaveLength(
		0,
	);
});

test("full: seats may free up, so check again", async () => {
	const refresh = vi.fn();
	const screen = await render(IntakePage, {
		page: page({ state: "full", action: "check_again" }),
		token,
		refresh,
	});

	await expect
		.element(
			screen.getByRole("heading", { name: "The workshop is full right now" }),
		)
		.toBeVisible();
	await expect.element(screen.getByText(/Seats can free up/)).toBeVisible();
	await screen.getByRole("button", { name: "Check again" }).click();
	expect(refresh).toHaveBeenCalledOnce();
});

test("paid: the place is confirmed, with no action", async () => {
	const screen = await render(IntakePage, {
		page: page({ state: "paid", action: "none" }),
		token,
	});

	await expect
		.element(screen.getByRole("heading", { name: "Your place is confirmed" }))
		.toBeVisible();
	await expect.element(screen.getByText("€40.00 · paid")).toBeVisible();
	expect(screen.getByRole("button").elements()).toHaveLength(0);
});

test("closed after the cutoff: payment has closed", async () => {
	const screen = await render(IntakePage, {
		page: page({
			state: "closed",
			action: "none",
			closedReason: "payment_closed",
		}),
		token,
	});

	await expect
		.element(screen.getByRole("heading", { name: "Payment has closed" }))
		.toBeVisible();
	expect(screen.getByRole("button").elements()).toHaveLength(0);
});

test("closed: an inactive (or unknown) link says it is no longer active and shows nothing else", async () => {
	const screen = await render(IntakePage, { page: INACTIVE_PAGE, token });

	await expect
		.element(
			screen.getByRole("heading", { name: "This link is no longer active" }),
		)
		.toBeVisible();
	expect(
		screen.getByRole("list", { name: "Workshop" }).elements(),
	).toHaveLength(0);
	expect(screen.getByRole("button").elements()).toHaveLength(0);
});

// ALE-388: a Carried Fee holder confirms instead of paying.
test("confirm: a Carried Fee holder gets one Confirm my place button and no fee", async () => {
	const screen = await render(IntakePage, {
		page: page({ state: "confirm", action: "confirm", feeCents: null }),
		token,
	});

	await expect
		.element(
			screen.getByRole("heading", {
				name: "Confirm your place at the Beginners' Workshop",
			}),
		)
		.toBeVisible();
	await expect.element(screen.getByText(/nothing to pay/)).toBeVisible();
	await expect
		.element(screen.getByRole("list", { name: "Workshop" }))
		.toHaveTextContent("St. Andrew's Hall");
	await expect
		.element(screen.getByRole("button", { name: "Confirm my place" }))
		.toBeEnabled();
	expect(screen.getByRole("button").elements()).toHaveLength(1);
	expect(screen.getByText("€40.00").elements()).toHaveLength(0);
	expect(screen.getByRole("button", { name: /Pay/ }).elements()).toHaveLength(
		0,
	);
	expect(
		document.querySelector("input[type=hidden]")?.getAttribute("value"),
	).toBe(token);
});

test("a Carried Fee holder who finds the workshop full keeps their fee and checks again", async () => {
	const refresh = vi.fn();
	const screen = await render(IntakePage, {
		page: page({ state: "full", action: "check_again", feeCents: null }),
		token,
		refresh,
	});

	await expect
		.element(screen.getByText(/Your Carried Fee is kept/))
		.toBeVisible();
	await screen.getByRole("button", { name: "Check again" }).click();
	expect(refresh).toHaveBeenCalledOnce();
});

test("paid by a Carried Fee: confirmed, with no fee shown", async () => {
	const screen = await render(IntakePage, {
		page: page({ state: "paid", action: "none", feeCents: null }),
		token,
	});

	await expect
		.element(screen.getByRole("heading", { name: "Your place is confirmed" }))
		.toBeVisible();
	await expect
		.element(screen.getByText(/Your Carried Fee covers your place/))
		.toBeVisible();
	expect(screen.getByText(/paid$/).elements()).toHaveLength(0);
	expect(screen.getByRole("button").elements()).toHaveLength(0);
});
