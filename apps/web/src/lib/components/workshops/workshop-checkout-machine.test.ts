import { describe, expect, it, vi } from "vitest";
import { createActor, fromPromise, waitFor } from "xstate";
import {
	workshopCheckoutMachine,
	workshopCheckoutMachineStates,
	workshopCheckoutPresentation,
	type WorkshopCheckoutImplementations,
} from "./workshop-checkout-machine";

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

const paymentIntent = {
	clientSecret: "cs_test_1",
	paymentIntentId: "pi_1",
};

function harness(
	options: {
		loadStripe?: () => Promise<void>;
		createPaymentIntent?: () => Promise<typeof paymentIntent>;
		preparePaymentElement?: () => Promise<void>;
		confirmPayment?: () => Promise<void>;
		completeRegistration?: () => Promise<void>;
		customerId?: string;
	} = {},
) {
	const loadStripe = vi.fn(options.loadStripe ?? (async () => {}));
	const createPaymentIntent = vi.fn(
		options.createPaymentIntent ?? (async () => paymentIntent),
	);
	const preparePaymentElement = vi.fn(
		options.preparePaymentElement ?? (async () => {}),
	);
	const confirmPayment = vi.fn(options.confirmPayment ?? (async () => {}));
	const completeRegistration = vi.fn(
		options.completeRegistration ?? (async () => {}),
	);
	const notifySuccess =
		vi.fn<WorkshopCheckoutImplementations["notifySuccess"]>();
	const notifyCancel = vi.fn<WorkshopCheckoutImplementations["notifyCancel"]>();

	const actor = createActor(
		workshopCheckoutMachine.provide({
			actors: {
				loadStripe: fromPromise(loadStripe),
				createPaymentIntent: fromPromise(createPaymentIntent),
				preparePaymentElement: fromPromise(preparePaymentElement),
				confirmPayment: fromPromise(confirmPayment),
				completeRegistration: fromPromise(completeRegistration),
			},
			actions: {
				notifySuccess: () => notifySuccess(),
				notifyCancel: () => notifyCancel(),
			},
		}),
		{
			input: {
				workshopId: "ws-1",
				customerId: options.customerId ?? "cus_1",
			},
		},
	);

	return {
		actor,
		loadStripe,
		createPaymentIntent,
		preparePaymentElement,
		confirmPayment,
		completeRegistration,
		notifySuccess,
		notifyCancel,
	};
}

const state = (actor: ReturnType<typeof harness>["actor"]) =>
	actor.getSnapshot().value;

describe("workshopCheckoutMachine", () => {
	it("loads Stripe, creates a payment intent, prepares the element, then is ready to confirm", async () => {
		const gate = deferred<void>();
		const { actor, loadStripe, createPaymentIntent, preparePaymentElement } =
			harness({
				loadStripe: () => gate.promise,
			});
		actor.start();

		expect(state(actor)).toBe("loadingStripe");
		expect(actor.getSnapshot().can({ type: "CONFIRM" })).toBe(false);

		gate.resolve();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));

		expect(loadStripe).toHaveBeenCalledTimes(1);
		expect(createPaymentIntent).toHaveBeenCalledTimes(1);
		expect(preparePaymentElement).toHaveBeenCalledTimes(1);
		expect(actor.getSnapshot().context.paymentIntentId).toBe("pi_1");
	});

	it("confirms payment, completes registration, then notifies success", async () => {
		const { actor, confirmPayment, completeRegistration, notifySuccess } =
			harness();
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));

		actor.send({ type: "CONFIRM" });
		expect(state(actor)).toBe("confirmingPayment");

		await waitFor(actor, (snapshot) => snapshot.matches("succeeded"));

		expect(confirmPayment).toHaveBeenCalledTimes(1);
		expect(completeRegistration).toHaveBeenCalledTimes(1);
		expect(notifySuccess).toHaveBeenCalledTimes(1);
	});

	it("a Stripe confirmation failure retries from ready without creating a new payment intent", async () => {
		let confirmAttempts = 0;
		const { actor, createPaymentIntent, confirmPayment, completeRegistration } =
			harness({
				confirmPayment: async () => {
					confirmAttempts += 1;
					if (confirmAttempts === 1) throw new Error("Your card was declined.");
				},
			});
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));

		actor.send({ type: "CONFIRM" });
		await waitFor(actor, (snapshot) => snapshot.matches("failed"));

		expect(actor.getSnapshot().context.failure).toEqual({
			message: "Your card was declined.",
			stage: "confirmingPayment",
		});

		actor.send({ type: "RETRY" });
		expect(state(actor)).toBe("ready");
		expect(actor.getSnapshot().context.failure).toBeUndefined();

		actor.send({ type: "CONFIRM" });
		await waitFor(actor, (snapshot) => snapshot.matches("succeeded"));

		expect(createPaymentIntent).toHaveBeenCalledTimes(1);
		expect(confirmPayment).toHaveBeenCalledTimes(2);
		expect(completeRegistration).toHaveBeenCalledTimes(1);
	});

	it("a registration-completion failure retries completion without confirming payment again", async () => {
		let completeAttempts = 0;
		const { actor, confirmPayment, completeRegistration, createPaymentIntent } =
			harness({
				completeRegistration: async () => {
					completeAttempts += 1;
					if (completeAttempts === 1) throw new Error("Registration failed");
				},
			});
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));
		actor.send({ type: "CONFIRM" });
		await waitFor(actor, (snapshot) => snapshot.matches("failed"));

		expect(actor.getSnapshot().context.failure).toEqual({
			message: "Registration failed",
			stage: "completingRegistration",
		});

		actor.send({ type: "RETRY" });
		await waitFor(actor, (snapshot) => snapshot.matches("succeeded"));

		expect(createPaymentIntent).toHaveBeenCalledTimes(1);
		expect(confirmPayment).toHaveBeenCalledTimes(1);
		expect(completeRegistration).toHaveBeenCalledTimes(2);
	});

	it("a payment-intent creation failure retries creation without reloading Stripe", async () => {
		let createAttempts = 0;
		const { actor, loadStripe, createPaymentIntent } = harness({
			createPaymentIntent: async () => {
				createAttempts += 1;
				if (createAttempts === 1)
					throw new Error("Failed to initialize payment");
				return paymentIntent;
			},
		});
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("failed"));

		expect(actor.getSnapshot().context.failure).toEqual({
			message: "Failed to initialize payment",
			stage: "creatingPaymentIntent",
		});

		actor.send({ type: "RETRY" });
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));

		expect(loadStripe).toHaveBeenCalledTimes(1);
		expect(createPaymentIntent).toHaveBeenCalledTimes(2);
	});

	it("a Stripe load failure retries from the start", async () => {
		let loadAttempts = 0;
		const { actor, loadStripe } = harness({
			loadStripe: async () => {
				loadAttempts += 1;
				if (loadAttempts === 1) throw new Error("Failed to load Stripe");
			},
		});
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("failed"));

		actor.send({ type: "RETRY" });
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));

		expect(loadStripe).toHaveBeenCalledTimes(2);
	});

	it("ignores repeated confirmations while confirming or completing", async () => {
		const gate = deferred<void>();
		const { actor, confirmPayment, completeRegistration } = harness({
			confirmPayment: () => gate.promise,
		});
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));

		actor.send({ type: "CONFIRM" });
		actor.send({ type: "CONFIRM" });
		expect(actor.getSnapshot().can({ type: "CONFIRM" })).toBe(false);

		gate.resolve();
		await waitFor(actor, (snapshot) => snapshot.matches("succeeded"));
		actor.send({ type: "CONFIRM" });

		expect(confirmPayment).toHaveBeenCalledTimes(1);
		expect(completeRegistration).toHaveBeenCalledTimes(1);
	});

	it("cancel is available before payment starts and notifies the host once", async () => {
		const { actor, notifyCancel, notifySuccess } = harness();
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));

		actor.send({ type: "CANCEL" });

		expect(state(actor)).toBe("cancelled");
		expect(notifyCancel).toHaveBeenCalledTimes(1);
		expect(notifySuccess).not.toHaveBeenCalled();
		expect(actor.getSnapshot().can({ type: "CONFIRM" })).toBe(false);
		expect(actor.getSnapshot().can({ type: "RETRY" })).toBe(false);
	});

	it("does not cancel once Stripe confirmation or registration completion has started", async () => {
		const gate = deferred<void>();
		const { actor, completeRegistration, notifyCancel } = harness({
			confirmPayment: () => gate.promise,
		});
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));
		actor.send({ type: "CONFIRM" });

		expect(actor.getSnapshot().can({ type: "CANCEL" })).toBe(false);
		actor.send({ type: "CANCEL" });
		expect(state(actor)).toBe("confirmingPayment");

		gate.resolve();
		await waitFor(actor, (snapshot) => snapshot.matches("succeeded"));
		expect(completeRegistration).toHaveBeenCalledTimes(1);
		expect(notifyCancel).not.toHaveBeenCalled();
	});

	it("stopping the actor discards in-flight payment work", async () => {
		const gate = deferred<void>();
		const { actor, completeRegistration, notifySuccess } = harness({
			confirmPayment: () => gate.promise,
		});
		actor.start();
		await waitFor(actor, (snapshot) => snapshot.matches("ready"));
		actor.send({ type: "CONFIRM" });

		actor.stop();
		gate.resolve();
		await Promise.resolve();

		expect(actor.getSnapshot().status).toBe("stopped");
		expect(completeRegistration).not.toHaveBeenCalled();
		expect(notifySuccess).not.toHaveBeenCalled();
	});

	it("every machine state has an intentional checkout presentation", () => {
		expect(Object.keys(workshopCheckoutMachine.states).sort()).toEqual(
			[...workshopCheckoutMachineStates].sort(),
		);
		expect(Object.keys(workshopCheckoutPresentation).sort()).toEqual(
			[...workshopCheckoutMachineStates].sort(),
		);
	});
});
