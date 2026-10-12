import type { StripeEmbeddedCheckoutOptions } from "@stripe/stripe-js";
import { expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import IntakeCheckout from "./intake-checkout.svelte";

function stripeStub() {
	let widget: HTMLParagraphElement | undefined;
	const embedded = {
		mount: vi.fn((container: HTMLElement) => {
			widget = document.createElement("p");
			widget.textContent = "Payment widget";
			container.appendChild(widget);
		}),
		destroy: vi.fn(() => widget?.remove()),
		unmount: vi.fn(),
	};
	const init = vi.fn(
		async (_options: StripeEmbeddedCheckoutOptions) => embedded,
	);
	return { embedded, init };
}

test("mounts secure payment in place, then asks Phoenix to confirm once Stripe completes", async () => {
	const { embedded, init } = stripeStub();
	const onComplete = vi.fn(async () => {});
	const screen = await render(IntakeCheckout, {
		clientSecret: "cs_test_secret",
		onComplete,
		createCheckout: init,
	});
	await vi.waitFor(() => expect(embedded.mount).toHaveBeenCalledOnce());
	expect(init.mock.calls[0][0].clientSecret).toBe("cs_test_secret");
	expect(onComplete).not.toHaveBeenCalled();
	await expect
		.element(screen.getByRole("region", { name: "Secure payment" }))
		.toBeVisible();
	init.mock.calls[0][0].onComplete?.();
	await vi.waitFor(() => expect(onComplete).toHaveBeenCalledOnce());
	expect(embedded.destroy).toHaveBeenCalledOnce();
	await screen.unmount();
	expect(embedded.destroy).toHaveBeenCalledOnce();
});

test("SDK failure uses safe copy and retries the same session, never a new payment", async () => {
	const { embedded, init } = stripeStub();
	init.mockRejectedValueOnce(new Error("cs_test_secret"));
	const screen = await render(IntakeCheckout, {
		clientSecret: "cs_test_secret",
		onComplete: async () => {},
		createCheckout: init,
	});
	await expect
		.element(
			screen.getByText("We couldn't load secure payment. Please try again."),
		)
		.toBeVisible();
	expect(screen.getByText("cs_test_secret").elements()).toHaveLength(0);
	await screen.getByRole("button", { name: "Try again" }).click();
	await vi.waitFor(() => expect(embedded.mount).toHaveBeenCalledOnce());
	expect(init.mock.calls[0][0].clientSecret).toBe("cs_test_secret");
});

test("a confirmation failure offers only Check payment, not another checkout", async () => {
	const { embedded, init } = stripeStub();
	const onComplete = vi
		.fn()
		.mockRejectedValueOnce(new Error("network"))
		.mockResolvedValue(undefined);
	const screen = await render(IntakeCheckout, {
		clientSecret: "cs_test_secret",
		onComplete,
		createCheckout: init,
	});
	await vi.waitFor(() => expect(embedded.mount).toHaveBeenCalledOnce());
	init.mock.calls[0][0].onComplete?.();
	await expect.element(screen.getByText(/don't pay twice/)).toBeVisible();
	await screen.getByRole("button", { name: "Check payment" }).click();
	await vi.waitFor(() => expect(onComplete).toHaveBeenCalledTimes(2));
	expect(init).toHaveBeenCalledOnce();
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
	const screen = await render(IntakeCheckout, {
		clientSecret: "cs_test_secret",
		onComplete: async () => {},
		createCheckout: init,
	});
	await vi.waitFor(() => expect(init).toHaveBeenCalledOnce());
	await screen.unmount();
	resolve(embedded);
	await vi.waitFor(() => expect(embedded.destroy).toHaveBeenCalledOnce());
	expect(embedded.mount).not.toHaveBeenCalled();
});
