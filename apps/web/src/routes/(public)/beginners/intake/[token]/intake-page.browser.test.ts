import type { BeginnersIntakePage } from "@dhc/api-client";
import type { StripeEmbeddedCheckoutOptions } from "@stripe/stripe-js";
import { expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import type { ComponentProps } from "svelte";
import { INACTIVE_PAGE } from "#lib/beginners-workshops/intake-page.js";
import type { IntakePaymentStart } from "#lib/beginners-workshops/intake-payment-machine.js";
import IntakePage from "./intake-page.svelte";

const token = "intake-link-token";
const opened: IntakePaymentStart = {
	ok: true,
	clientSecret: "cs_test_secret",
	sessionId: "cs_test",
};

/** A start that never answers, so the page stays on its loading line. */
const pending = () => new Promise<IntakePaymentStart>(() => {});

function stripeStub() {
	let widget: HTMLParagraphElement | undefined;
	const embedded = {
		mount: vi.fn((container: HTMLElement) => {
			widget = document.createElement("p");
			widget.textContent = "Payment widget";
			container.appendChild(widget);
		}),
		destroy: vi.fn(() => widget?.remove()),
	};
	const init = vi.fn(
		async (_options: StripeEmbeddedCheckoutOptions) => embedded,
	);
	return { embedded, init };
}

function renderPage(props: ComponentProps<typeof IntakePage>) {
	return render(IntakePage, { startPayment: pending, ...props });
}

test("a failed automatic start shows a safe error and only then offers Try again", async () => {
	const startPayment = vi.fn(async (): Promise<IntakePaymentStart> => {
		throw new Error("credential-must-not-render");
	});
	const screen = await renderPage({ page: page(), token, startPayment });
	await expect
		.element(
			screen.getByText(
				"Payment is unavailable right now. Please try again shortly.",
			),
		)
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Try again" }))
		.toBeVisible();
	expect(
		screen.getByText("credential-must-not-render").elements(),
	).toHaveLength(0);
	expect(startPayment).toHaveBeenCalledOnce();
});

test("Try again starts payment once more and mounts the session it opens", async () => {
	const { embedded, init } = stripeStub();
	const startPayment = vi
		.fn<() => Promise<IntakePaymentStart>>()
		.mockResolvedValueOnce({ ok: false, error: "The workshop is full." })
		.mockResolvedValueOnce(opened);
	const screen = await renderPage({
		page: page(),
		token,
		startPayment,
		createCheckout: init,
	});
	await expect.element(screen.getByText("The workshop is full.")).toBeVisible();
	await screen.getByRole("button", { name: "Try again" }).click();
	await vi.waitFor(() => expect(embedded.mount).toHaveBeenCalledOnce());
	expect(startPayment).toHaveBeenCalledTimes(2);
	expect(init.mock.calls[0][0].clientSecret).toBe("cs_test_secret");
	expect(screen.getByText("The workshop is full.").elements()).toHaveLength(0);
});

test.each(["pay", "continue_payment"] as const)(
	"%s opens payment automatically, once",
	async (action) => {
		const startPayment = vi.fn(pending);
		const screen = await renderPage({
			page: page({ action }),
			token,
			startPayment,
		});
		await vi.waitFor(() => expect(startPayment).toHaveBeenCalledOnce());
		await screen.rerender({ page: page({ action }), token, startPayment });
		expect(startPayment).toHaveBeenCalledOnce();
	},
);

test("the reload after the POST keeps the open widget in place", async () => {
	const { embedded, init } = stripeStub();
	const startPayment = vi.fn(async () => opened);
	const screen = await renderPage({
		page: page(),
		token,
		startPayment,
		createCheckout: init,
	});
	await vi.waitFor(() => expect(embedded.mount).toHaveBeenCalledOnce());
	// Phoenix now reports the live hold the POST took.
	await screen.rerender({ page: page({ action: "continue_payment" }) });
	await expect.element(screen.getByText("Payment widget")).toBeVisible();
	expect(init).toHaveBeenCalledOnce();
	expect(embedded.destroy).not.toHaveBeenCalled();
	expect(startPayment).toHaveBeenCalledOnce();
});

test("once the view left payment, a returning payment action is started by hand", async () => {
	const { embedded, init } = stripeStub();
	const startPayment = vi.fn(async () => opened);
	const screen = await renderPage({
		page: page(),
		token,
		startPayment,
		createCheckout: init,
		refresh: vi.fn(),
		refreshMs: 60_000,
	});
	await vi.waitFor(() => expect(embedded.mount).toHaveBeenCalledOnce());
	await screen.rerender({
		page: page({ state: "payment_in_progress", action: "check_again" }),
	});
	await vi.waitFor(() => expect(embedded.destroy).toHaveBeenCalledOnce());
	await screen.rerender({ page: page() });
	await expect
		.element(screen.getByRole("button", { name: "Pay for your place" }))
		.toBeVisible();
	expect(startPayment).toHaveBeenCalledOnce();
	expect(init).toHaveBeenCalledOnce();
	await screen.getByRole("button", { name: "Pay for your place" }).click();
	await vi.waitFor(() => expect(init).toHaveBeenCalledTimes(2));
	expect(startPayment).toHaveBeenCalledTimes(2);
});

test.each(["confirm", "check_again", "none"] as const)(
	"%s never starts a payment automatically",
	async (action) => {
		const startPayment = vi.fn(pending);
		await renderPage({ page: page({ action }), token, startPayment });
		expect(startPayment).not.toHaveBeenCalled();
	},
);

test("pay shows Phoenix's deadline on the Dublin clock", async () => {
	const screen = await renderPage({
		page: page({ paymentCutoff: "2026-11-11T18:00:00Z" }),
		token,
	});
	await expect
		.element(screen.getByText("Payment deadline: Wed 11 Nov, 18:00"))
		.toBeVisible();
});

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
			endTime: null,
			venue: "St. Andrew's Hall",
		},
		feeCents: 4000,
		...overrides,
	};
}

test("pay: the person's name, the workshop, the fee and payment loading with no extra Pay button", async () => {
	const screen = await renderPage({ page: page(), token });

	await expect.element(screen.getByText("Hi Aoife,")).toBeVisible();
	const workshop = screen.getByRole("list", { name: "Workshop" });
	await expect.element(workshop).toHaveTextContent("Sat 14 Nov 2026");
	await expect.element(workshop).toHaveTextContent("18:30");
	await expect.element(workshop).toHaveTextContent("St. Andrew's Hall");
	await expect.element(screen.getByText("€40.00")).toBeVisible();
	await expect
		.element(screen.getByRole("status"))
		.toHaveTextContent("Loading secure payment…");
	expect(
		screen.getByRole("button", { name: "Pay for your place" }).elements(),
	).toHaveLength(0);
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

test("pay with a live hold opens checkout without a Continue button", async () => {
	const screen = await renderPage({
		page: page({ action: "continue_payment" }),
		token,
	});

	await expect
		.element(screen.getByRole("status"))
		.toHaveTextContent("Loading secure payment…");
	expect(
		screen.getByRole("button", { name: "Continue to payment" }).elements(),
	).toHaveLength(0);
});

test("payment_in_progress refreshes on its own, once per view, until Phoenix reports paid", async () => {
	const refresh = vi.fn();
	const inProgress = () =>
		page({ state: "payment_in_progress", action: "check_again" });
	const screen = await render(IntakePage, {
		page: inProgress(),
		token,
		refresh,
		refreshMs: 20,
	});

	await expect
		.element(screen.getByRole("heading", { name: "Payment in progress" }))
		.toBeVisible();
	await expect.element(screen.getByText(/no need to pay again/)).toBeVisible();
	await vi.waitFor(() => expect(refresh).toHaveBeenCalledOnce());
	expect(screen.getByRole("button", { name: /Pay/ }).elements()).toHaveLength(
		0,
	);
	// Phoenix's next view, still in progress, arms the next refresh.
	await screen.rerender({ page: inProgress() });
	await vi.waitFor(() => expect(refresh).toHaveBeenCalledTimes(2));
	await screen.rerender({ page: page({ state: "paid", action: "none" }) });
	await new Promise((done) => setTimeout(done, 60));
	expect(refresh).toHaveBeenCalledTimes(2);
});

test("full: places may free up, so check again", async () => {
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
	await expect.element(screen.getByText(/Places can free up/)).toBeVisible();
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
		.element(screen.getByText(/Your workshop credit is kept/))
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
		.element(screen.getByText(/Your workshop credit covers your place/))
		.toBeVisible();
	expect(screen.getByText(/paid$/).elements()).toHaveLength(0);
	expect(screen.getByRole("button").elements()).toHaveLength(0);
});
