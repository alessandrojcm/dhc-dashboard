import type { StripeEmbeddedCheckoutOptions } from "@stripe/stripe-js";
import { expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import WorkshopRegistrationCheckout from "./workshop-registration-checkout.svelte";

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

test("shows loading, then mounts the session's widget in its container", async () => {
	const { embedded, init } = stripeStub();
	let resolve!: (value: typeof embedded) => void;
	init.mockImplementationOnce(
		() =>
			new Promise((done) => {
				resolve = done;
			}),
	);
	const screen = await render(WorkshopRegistrationCheckout, {
		clientSecret: "cs_test_secret",
		stripeConfigured: true,
		createCheckout: init,
	});
	await expect
		.element(screen.getByText("Loading payment form..."))
		.toBeVisible();
	await vi.waitFor(() => expect(init).toHaveBeenCalledOnce());
	expect(init.mock.calls[0][0].clientSecret).toBe("cs_test_secret");

	resolve(embedded);
	await expect.element(screen.getByText("Payment widget")).toBeVisible();
	expect(embedded.mount).toHaveBeenCalledOnce();
	expect(embedded.mount.mock.calls[0][0].id).toBe("workshop-checkout");
	expect(screen.getByText("Loading payment form...").elements()).toHaveLength(
		0,
	);
	expect(screen.getByText("Registration error").elements()).toHaveLength(0);
});

test("an initialization failure shows safe registration-error copy and retries in place", async () => {
	const { embedded, init } = stripeStub();
	init.mockRejectedValueOnce(new Error("cs_test_secret"));
	const screen = await render(WorkshopRegistrationCheckout, {
		clientSecret: "cs_test_secret",
		stripeConfigured: true,
		createCheckout: init,
	});

	await expect.element(screen.getByText("Registration error")).toBeVisible();
	await expect
		.element(
			screen.getByText("Failed to initialize checkout. Please try again."),
		)
		.toBeVisible();
	expect(screen.getByText("cs_test_secret").elements()).toHaveLength(0);
	await screen.getByRole("button", { name: "Try again" }).click();

	await expect.element(screen.getByText("Payment widget")).toBeVisible();
	expect(init).toHaveBeenCalledTimes(2);
	expect(init.mock.calls[1][0].clientSecret).toBe("cs_test_secret");
	expect(embedded.mount).toHaveBeenCalledOnce();
	expect(screen.getByText("Registration error").elements()).toHaveLength(0);
	expect(
		screen.getByRole("button", { name: "Try again" }).elements(),
	).toHaveLength(0);
});

test.each([
	[
		{ stripeConfigured: false, clientSecret: "cs_test_secret" },
		"Payment is currently unavailable. Please try again later.",
	],
	[
		{ stripeConfigured: true, clientSecret: null },
		"Failed to initialize checkout. Please refresh and try again.",
	],
])(
	"%o shows the registration error without loading Stripe",
	async (props, message) => {
		const { init } = stripeStub();
		const screen = await render(WorkshopRegistrationCheckout, {
			...props,
			createCheckout: init,
		});
		await expect.element(screen.getByText(message)).toBeVisible();
		expect(
			screen.getByRole("button", { name: "Try again" }).elements(),
		).toHaveLength(0);
		expect(screen.getByText("Loading payment form...").elements()).toHaveLength(
			0,
		);
		expect(init).not.toHaveBeenCalled();
	},
);

test("leaving the page destroys the mounted widget", async () => {
	const { embedded, init } = stripeStub();
	const screen = await render(WorkshopRegistrationCheckout, {
		clientSecret: "cs_test_secret",
		stripeConfigured: true,
		createCheckout: init,
	});
	await vi.waitFor(() => expect(embedded.mount).toHaveBeenCalledOnce());
	await screen.unmount();
	expect(embedded.destroy).toHaveBeenCalledOnce();
});

test("destroys a late SDK instance rather than mounting after the page is gone", async () => {
	const { embedded, init } = stripeStub();
	let resolve!: (value: typeof embedded) => void;
	init.mockImplementationOnce(
		() =>
			new Promise((done) => {
				resolve = done;
			}),
	);
	const screen = await render(WorkshopRegistrationCheckout, {
		clientSecret: "cs_test_secret",
		stripeConfigured: true,
		createCheckout: init,
	});
	await vi.waitFor(() => expect(init).toHaveBeenCalledOnce());
	await screen.unmount();
	resolve(embedded);
	await vi.waitFor(() => expect(embedded.destroy).toHaveBeenCalledOnce());
	expect(embedded.mount).not.toHaveBeenCalled();
});
