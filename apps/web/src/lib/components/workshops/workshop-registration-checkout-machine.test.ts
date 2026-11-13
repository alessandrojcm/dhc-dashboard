import type { StripeEmbeddedCheckoutOptions } from "@stripe/stripe-js";
import { describe, expect, it, vi } from "vitest";
import { createActor } from "xstate";
import { embeddedCheckoutWidget } from "#lib/stripe/embedded-checkout-widget.js";
import {
	workshopRegistrationCheckoutMachine,
	workshopRegistrationCheckoutView,
	type WorkshopRegistrationCheckoutInput,
} from "./workshop-registration-checkout-machine";

type Deferred<T> = {
	promise: Promise<T>;
	resolve: (value: T) => void;
	reject: (error: Error) => void;
};

function deferred<T>(): Deferred<T> {
	let resolve!: (value: T) => void;
	let reject!: (error: Error) => void;
	const promise = new Promise<T>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	return { promise, resolve, reject };
}

const settle = () => new Promise((done) => setTimeout(done, 0));

/** A fake Stripe: every widget it creates, and the options it was given. */
function fakeStripe() {
	const widgets: {
		mount: ReturnType<typeof vi.fn>;
		destroy: ReturnType<typeof vi.fn>;
	}[] = [];
	const options: StripeEmbeddedCheckoutOptions[] = [];
	const create = vi.fn(async (given: StripeEmbeddedCheckoutOptions) => {
		options.push(given);
		const widget = { mount: vi.fn(), destroy: vi.fn() };
		widgets.push(widget);
		return widget;
	});
	return { create, widgets, options };
}

// SAFETY: the fake widgets never touch their container; the machine only
// passes it through to `mount`, so any object stands in for the element.
const container = {} as HTMLElement;

function harness(
	stripe = fakeStripe(),
	input: Partial<WorkshopRegistrationCheckoutInput> = {},
) {
	const actor = createActor(
		workshopRegistrationCheckoutMachine.provide({
			actors: {
				widget: embeddedCheckoutWidget(stripe.create, () => container),
			},
		}),
		{
			input: {
				clientSecret: "cs_test_secret",
				stripeConfigured: true,
				...input,
			},
		},
	).start();
	const view = () => workshopRegistrationCheckoutView(actor.getSnapshot());
	return { actor, stripe, view };
}

describe("the regular-Workshop registration checkout machine (ALE-447)", () => {
	it("loads nothing until the browser has mounted the host", async () => {
		const { actor, stripe, view } = harness();
		await settle();
		expect(stripe.create).not.toHaveBeenCalled();
		expect(view()).toEqual({
			phase: "loading",
			status: "Loading payment form...",
			failure: null,
			retry: null,
		});
		actor.send({ type: "MOUNTED" });
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(stripe.create).toHaveBeenCalledOnce();
	});

	it("mounts the session's widget, and Stripe's completion leaves it to the redirect", async () => {
		const { actor, stripe, view } = harness();
		actor.send({ type: "MOUNTED" });
		expect(view().phase).toBe("loading");
		await settle();
		expect(view()).toEqual({
			phase: "active",
			status: null,
			failure: null,
			retry: null,
		});
		expect(stripe.options[0].clientSecret).toBe("cs_test_secret");
		expect(stripe.widgets[0].mount).toHaveBeenCalledWith(container);

		// Stripe redirects to the confirmation page; a completion (or any
		// repeated event) neither destroys nor recreates the widget.
		stripe.options[0].onComplete?.();
		actor.send({ type: "WIDGET.COMPLETED" });
		actor.send({ type: "WIDGET.MOUNTED" });
		actor.send({ type: "RETRY" });
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(view().phase).toBe("active");
		expect(stripe.widgets[0].destroy).not.toHaveBeenCalled();
		expect(stripe.create).toHaveBeenCalledOnce();

		actor.stop();
		expect(stripe.widgets[0].destroy).toHaveBeenCalledOnce();
	});

	it.each([
		[
			{ stripeConfigured: false },
			"paymentUnavailable",
			"Payment is currently unavailable. Please try again later.",
		],
		[
			{ clientSecret: null },
			"sessionMissing",
			"Failed to initialize checkout. Please refresh and try again.",
		],
	] as const)(
		"%o is unavailable without loading Stripe",
		async (input, phase, failure) => {
			const { actor, stripe, view } = harness(fakeStripe(), input);
			expect(view()).toEqual({ phase, status: null, failure, retry: null });
			actor.send({ type: "MOUNTED" });
			actor.send({ type: "RETRY" });
			await settle();
			expect(view().phase).toBe(phase);
			expect(stripe.create).not.toHaveBeenCalled();
		},
	);

	it("an initialization failure shows fixed copy and retries the same session", async () => {
		const stripe = fakeStripe();
		stripe.create.mockRejectedValueOnce(new Error("cs_test_secret leaked"));
		const { actor, view } = harness(stripe);
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(view()).toEqual({
			phase: "initFailed",
			status: null,
			failure: "Failed to initialize checkout. Please try again.",
			retry: "Try again",
		});
		expect(JSON.stringify(actor.getSnapshot().context)).not.toContain("leaked");

		actor.send({ type: "RETRY" });
		actor.send({ type: "RETRY" });
		expect(view().phase).toBe("loading");
		await settle();
		expect(view().phase).toBe("active");
		expect(stripe.create).toHaveBeenCalledTimes(2);
		expect(stripe.options[0].clientSecret).toBe("cs_test_secret");
		expect(stripe.widgets[0].mount).toHaveBeenCalledOnce();
	});

	it("a widget that fails to mount is destroyed and offers initialization retry", async () => {
		const stripe = fakeStripe();
		stripe.create.mockImplementationOnce(async (given) => {
			stripe.options.push(given);
			const widget = {
				mount: vi.fn(() => {
					throw new Error("boom");
				}),
				destroy: vi.fn(),
			};
			stripe.widgets.push(widget);
			return widget;
		});
		const { actor, view } = harness(stripe);
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(view().phase).toBe("initFailed");
		expect(stripe.widgets[0].destroy).toHaveBeenCalledOnce();
	});

	it("disposal mid-initialization destroys the late widget instead of mounting it", async () => {
		const widget = { mount: vi.fn(), destroy: vi.fn() };
		const late = deferred<typeof widget>();
		const stripe = fakeStripe();
		stripe.create.mockImplementationOnce((given) => {
			stripe.options.push(given);
			return late.promise;
		});
		const { actor } = harness(stripe);
		actor.send({ type: "MOUNTED" });
		await settle();
		const observed = vi.fn();
		actor.subscribe(observed);
		actor.stop();
		late.resolve(widget);
		await settle();
		expect(widget.destroy).toHaveBeenCalledOnce();
		expect(widget.mount).not.toHaveBeenCalled();
		// Its Stripe callback is dropped too.
		expect(() => stripe.options[0].onComplete?.()).not.toThrow();
		expect(observed).not.toHaveBeenCalled();
		expect(actor.getSnapshot().status).toBe("stopped");
	});

	it("a late failure after disposal is discarded", async () => {
		const late = deferred<never>();
		const stripe = fakeStripe();
		stripe.create.mockImplementationOnce(() => late.promise);
		const { actor } = harness(stripe);
		actor.send({ type: "MOUNTED" });
		await settle();
		actor.stop();
		late.reject(new Error("late"));
		await settle();
		expect(actor.getSnapshot().value).toEqual({ collecting: "loading" });
	});
});
