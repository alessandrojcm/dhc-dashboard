import { describe, expect, it, vi } from "vitest";
import { createActor, fromPromise, waitFor } from "xstate";
import {
	paymentMachine,
	paymentMachineStates,
	paymentSubmitPresentation,
	type PaymentMachineImplementations,
} from "./payment-machine";

type Deferred<T> = {
	promise: Promise<T>;
	resolve: (value: T) => void;
};

function deferred<T>(): Deferred<T> {
	let resolve!: (value: T) => void;
	const promise = new Promise<T>((res) => {
		resolve = res;
	});
	return { promise, resolve };
}

function harness(
	options: {
		complimentary?: boolean;
		load?: () => Promise<void>;
		prepare?: () => Promise<{ confirmationToken: string | undefined }>;
	} = {},
) {
	const load = vi.fn(options.load ?? (async () => {}));
	const prepare = vi.fn(
		options.prepare ?? (async () => ({ confirmationToken: "ctoken_1" })),
	);
	const submit = vi.fn<PaymentMachineImplementations["submitPayment"]>();

	const actor = createActor(
		paymentMachine.provide({
			actors: {
				loadPaymentElement: fromPromise(load),
				preparePayment: fromPromise(prepare),
			},
			actions: {
				submitPayment: (_, params) => submit(params),
			},
		}),
		{ input: { complimentary: options.complimentary ?? false } },
	);

	return { actor, load, prepare, submit };
}

const state = (actor: ReturnType<typeof harness>["actor"]) =>
	actor.getSnapshot().value;

describe("paymentMachine", () => {
	it("skips Stripe initialization for a complimentary invitation", () => {
		const { actor, load } = harness({ complimentary: true });
		actor.start();

		expect(state(actor)).toBe("ready");
		expect(load).not.toHaveBeenCalled();
	});

	it("initializes the payment element before accepting a payment request", async () => {
		const gate = deferred<void>();
		const { actor } = harness({ load: () => gate.promise });
		actor.start();

		expect(state(actor)).toBe("initializing");
		expect(actor.getSnapshot().can({ type: "PAYMENT_REQUESTED" })).toBe(false);

		gate.resolve();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));
	});

	it("enters an explicit unavailable state when Stripe fails to load and can retry", async () => {
		let attempts = 0;
		const { actor, load } = harness({
			load: async () => {
				attempts += 1;
				if (attempts === 1) throw new Error("stripe.js blocked");
			},
		});
		actor.start();

		await waitFor(actor, (snapshot) => snapshot.matches("unavailable"));
		expect(actor.getSnapshot().context.failure).toEqual({
			message: "stripe.js blocked",
			recoverable: true,
		});

		actor.send({ type: "RETRY_REQUESTED" });
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));
		expect(load).toHaveBeenCalledTimes(2);
	});

	it("prepares the Stripe confirmation token, then submits exactly once", async () => {
		const { actor, prepare, submit } = harness();
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));

		actor.send({ type: "PAYMENT_REQUESTED" });
		expect(state(actor)).toBe("preparing");

		await waitFor(actor, (snapshot) => snapshot.matches("submitting"));
		expect(prepare).toHaveBeenCalledTimes(1);
		expect(submit).toHaveBeenCalledTimes(1);
		expect(submit).toHaveBeenCalledWith({ confirmationToken: "ctoken_1" });
	});

	it("submits without a token for a complimentary invitation", async () => {
		const { actor, submit } = harness({
			complimentary: true,
			prepare: async () => ({ confirmationToken: undefined }),
		});
		actor.start();

		actor.send({ type: "PAYMENT_REQUESTED" });
		await waitFor(actor, (snapshot) => snapshot.matches("submitting"));

		expect(submit).toHaveBeenCalledWith({ confirmationToken: undefined });
	});

	it("ignores repeated payment requests while preparing or submitting", async () => {
		const gate = deferred<{ confirmationToken: string | undefined }>();
		const { actor, prepare, submit } = harness({ prepare: () => gate.promise });
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));

		actor.send({ type: "PAYMENT_REQUESTED" });
		actor.send({ type: "PAYMENT_REQUESTED" });
		expect(actor.getSnapshot().can({ type: "PAYMENT_REQUESTED" })).toBe(false);

		gate.resolve({ confirmationToken: "ctoken_1" });
		await waitFor(actor, (snapshot) => snapshot.matches("submitting"));
		actor.send({ type: "PAYMENT_REQUESTED" });

		expect(prepare).toHaveBeenCalledTimes(1);
		expect(submit).toHaveBeenCalledTimes(1);
		expect(state(actor)).toBe("submitting");
	});

	it("a recoverable submission failure can be retried from the ready state", async () => {
		const { actor, prepare } = harness();
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));
		actor.send({ type: "PAYMENT_REQUESTED" });
		await waitFor(actor, (snapshot) => snapshot.matches("submitting"));

		actor.send({
			type: "SUBMISSION_FAILED",
			message: "Payment could not be completed",
			recoverable: true,
		});

		expect(state(actor)).toBe("failed");
		expect(actor.getSnapshot().context.failure).toEqual({
			message: "Payment could not be completed",
			recoverable: true,
		});

		actor.send({ type: "RETRY_REQUESTED" });
		expect(state(actor)).toBe("ready");
		expect(actor.getSnapshot().context.failure).toBeUndefined();

		actor.send({ type: "PAYMENT_REQUESTED" });
		await waitFor(actor, (snapshot) => snapshot.matches("submitting"));
		expect(prepare).toHaveBeenCalledTimes(2);
	});

	it("a non-recoverable failure is terminal: the proof is gone and the browser cannot overrule Phoenix", async () => {
		const { actor, submit } = harness();
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));
		actor.send({ type: "PAYMENT_REQUESTED" });
		await waitFor(actor, (snapshot) => snapshot.matches("submitting"));

		actor.send({
			type: "SUBMISSION_FAILED",
			message: "Invitation verification has expired. Please verify again.",
			recoverable: false,
		});

		expect(state(actor)).toBe("expired");
		expect(actor.getSnapshot().can({ type: "PAYMENT_REQUESTED" })).toBe(false);
		expect(actor.getSnapshot().can({ type: "RETRY_REQUESTED" })).toBe(false);
		actor.send({ type: "PAYMENT_REQUESTED" });
		expect(submit).toHaveBeenCalledTimes(1);
	});

	it("a Stripe token failure is a recoverable failure with Stripe's message", async () => {
		const { actor, submit } = harness({
			prepare: async () => {
				throw new Error("Your IBAN is incomplete.");
			},
		});
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));

		actor.send({ type: "PAYMENT_REQUESTED" });
		await waitFor(actor, (snapshot) => snapshot.matches("failed"));

		expect(actor.getSnapshot().context.failure).toEqual({
			message: "Your IBAN is incomplete.",
			recoverable: true,
		});
		expect(submit).not.toHaveBeenCalled();
	});

	it("stopping the actor discards in-flight Stripe work", async () => {
		const gate = deferred<{ confirmationToken: string | undefined }>();
		const { actor, submit } = harness({ prepare: () => gate.promise });
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));
		actor.send({ type: "PAYMENT_REQUESTED" });

		actor.stop();
		gate.resolve({ confirmationToken: "late" });
		await Promise.resolve();

		expect(actor.getSnapshot().status).toBe("stopped");
		expect(submit).not.toHaveBeenCalled();
	});

	it("every machine state has an intentional submit-control presentation", () => {
		expect(Object.keys(paymentMachine.states).sort()).toEqual(
			[...paymentMachineStates].sort(),
		);
		expect(Object.keys(paymentSubmitPresentation).sort()).toEqual(
			[...paymentMachineStates].sort(),
		);
	});
});
