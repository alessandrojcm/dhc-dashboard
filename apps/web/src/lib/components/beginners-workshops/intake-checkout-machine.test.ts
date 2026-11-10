import type { StripeEmbeddedCheckoutOptions } from "@stripe/stripe-js";
import { describe, expect, it, vi } from "vitest";
import { createActor, fromPromise } from "xstate";
import { embeddedCheckoutWidget } from "#lib/stripe/embedded-checkout-widget.js";
import {
	intakeCheckoutMachine,
	intakeCheckoutView,
} from "./intake-checkout-machine";

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
	/** Stripe's completion callback for the nth widget. */
	const complete = (n = 0) => options[n].onComplete?.();
	return { create, widgets, options, complete };
}

// SAFETY: the fake widgets never touch their container; the machine only
// passes it through to `mount`, so any object stands in for the element.
const container = {} as HTMLElement;

function harness(
	stripe = fakeStripe(),
	confirm: () => Promise<void> = async () => {},
) {
	const confirmSpy = vi.fn(confirm);
	const actor = createActor(
		intakeCheckoutMachine.provide({
			actors: {
				widget: embeddedCheckoutWidget(stripe.create, () => container),
				confirm: fromPromise(() => confirmSpy()),
			},
		}),
		{ input: { clientSecret: "cs_test_secret" } },
	).start();
	const phase = () => intakeCheckoutView(actor.getSnapshot()).phase;
	return { actor, stripe, confirm: confirmSpy, phase };
}

describe("the Intake checkout widget machine (ALE-447)", () => {
	it("loads nothing until the browser has mounted the host", async () => {
		const { actor, stripe, phase } = harness();
		await settle();
		expect(stripe.create).not.toHaveBeenCalled();
		expect(phase()).toBe("loading");
		actor.send({ type: "MOUNTED" });
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(stripe.create).toHaveBeenCalledOnce();
	});

	it("mounts the session, destroys collection on completion, then asks Phoenix", async () => {
		const confirmation = deferred<void>();
		const { actor, stripe, confirm, phase } = harness(
			fakeStripe(),
			() => confirmation.promise,
		);
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(phase()).toBe("active");
		expect(stripe.options[0].clientSecret).toBe("cs_test_secret");
		expect(stripe.widgets[0].mount).toHaveBeenCalledWith(container);
		expect(confirm).not.toHaveBeenCalled();

		stripe.complete();
		expect(phase()).toBe("confirming");
		expect(stripe.widgets[0].destroy).toHaveBeenCalledOnce();
		expect(confirm).toHaveBeenCalledOnce();
		expect(intakeCheckoutView(actor.getSnapshot()).status).toBe(
			"Confirming your payment…",
		);

		confirmation.resolve();
		await settle();
		expect(phase()).toBe("confirmed");
		actor.stop();
		expect(stripe.widgets[0].destroy).toHaveBeenCalledOnce();
		expect(stripe.create).toHaveBeenCalledOnce();
	});

	it("an initialization failure retries initialization for the same session", async () => {
		const stripe = fakeStripe();
		stripe.create.mockRejectedValueOnce(new Error("cs_test_secret leaked"));
		const { actor, confirm, phase } = harness(stripe);
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(phase()).toBe("initFailed");
		const view = intakeCheckoutView(actor.getSnapshot());
		expect(view.failure).toBe(
			"We couldn't load secure payment. Please try again.",
		);
		expect(JSON.stringify(view)).not.toContain("cs_test_secret");
		expect(view.retry).toBe("Try again");

		actor.send({ type: "RETRY" });
		expect(phase()).toBe("loading");
		await settle();
		expect(phase()).toBe("active");
		expect(stripe.create).toHaveBeenCalledTimes(2);
		expect(stripe.options[0].clientSecret).toBe("cs_test_secret");
		expect(stripe.widgets[0].mount).toHaveBeenCalledOnce();
		expect(confirm).not.toHaveBeenCalled();
	});

	it("a widget that fails to mount is destroyed and offers initialization retry", async () => {
		const stripe = fakeStripe();
		const { actor, phase } = harness(stripe);
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
		actor.send({ type: "MOUNTED" });
		await settle();
		expect(phase()).toBe("initFailed");
		expect(stripe.widgets[0].destroy).toHaveBeenCalledOnce();
	});

	it("a confirmation failure retries only confirmation: collection never remounts", async () => {
		const stripe = fakeStripe();
		const confirm = vi
			.fn<() => Promise<void>>()
			.mockRejectedValueOnce(new Error("network"))
			.mockResolvedValue(undefined);
		const { actor, phase } = harness(stripe, confirm);
		actor.send({ type: "MOUNTED" });
		await settle();
		stripe.complete();
		await settle();
		expect(phase()).toBe("confirmFailed");
		const view = intakeCheckoutView(actor.getSnapshot());
		expect(view.failure).toBe(
			"We couldn't check your payment yet. Check again — don't pay twice.",
		);
		expect(view.retry).toBe("Check payment");

		// A late or repeated Stripe callback cannot start anything new.
		stripe.complete();
		actor.send({ type: "WIDGET.COMPLETED" });
		actor.send({ type: "WIDGET.MOUNTED" });
		await settle();
		expect(phase()).toBe("confirmFailed");
		expect(confirm).toHaveBeenCalledOnce();

		actor.send({ type: "RETRY" });
		expect(phase()).toBe("confirming");
		actor.send({ type: "RETRY" });
		await settle();
		expect(phase()).toBe("confirmed");
		expect(confirm).toHaveBeenCalledTimes(2);
		expect(stripe.create).toHaveBeenCalledOnce();
		expect(stripe.widgets[0].mount).toHaveBeenCalledOnce();
	});

	it("a repeated completion confirms once", async () => {
		const confirmation = deferred<void>();
		const { actor, stripe, confirm } = harness(
			fakeStripe(),
			() => confirmation.promise,
		);
		actor.send({ type: "MOUNTED" });
		await settle();
		stripe.complete();
		stripe.complete();
		actor.send({ type: "RETRY" });
		expect(confirm).toHaveBeenCalledOnce();
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
		actor.stop();
		late.resolve(widget);
		await settle();
		expect(widget.destroy).toHaveBeenCalledOnce();
		expect(widget.mount).not.toHaveBeenCalled();
		// Its Stripe callback is dropped too.
		expect(() => stripe.complete()).not.toThrow();
		expect(actor.getSnapshot().status).toBe("stopped");
	});

	it("disposal mid-confirmation discards Phoenix's late answer", async () => {
		const confirmation = deferred<void>();
		const { actor, stripe } = harness(fakeStripe(), () => confirmation.promise);
		actor.send({ type: "MOUNTED" });
		await settle();
		stripe.complete();
		const observed = vi.fn();
		actor.subscribe(observed);
		actor.stop();
		confirmation.reject(new Error("late"));
		await settle();
		expect(actor.getSnapshot().value).toBe("confirming");
		expect(observed).not.toHaveBeenCalled();
		expect(stripe.widgets[0].destroy).toHaveBeenCalledOnce();
	});
});
