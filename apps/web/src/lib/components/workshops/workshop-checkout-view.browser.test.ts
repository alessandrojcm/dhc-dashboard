import { expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import { createActor, fromPromise, waitFor } from "xstate";
import {
	workshopCheckoutMachine,
	workshopCheckoutMachineStates,
	workshopCheckoutPresentation,
	type CheckoutFailure,
	type WorkshopCheckoutState,
} from "./workshop-checkout-machine";
import WorkshopCheckoutView from "./workshop-checkout-view.svelte";

const failure: CheckoutFailure = {
	message: "Your card was declined.",
	stage: "confirmingPayment",
};

async function renderState(
	state: WorkshopCheckoutState,
	overrides: Partial<{
		failure: CheckoutFailure | undefined;
		onconfirm: () => void;
		onretry: () => void;
		oncancel: () => void;
	}> = {},
) {
	return await render(WorkshopCheckoutView, {
		state,
		failure: overrides.failure,
		workshopTitle: "Longsword fundamentals",
		amount: 2500,
		onconfirm: overrides.onconfirm ?? vi.fn(),
		onretry: overrides.onretry ?? vi.fn(),
		oncancel: overrides.oncancel ?? vi.fn(),
	});
}

test.each(workshopCheckoutMachineStates)(
	"%s renders its intentional checkout presentation",
	async (state) => {
		const presentation = workshopCheckoutPresentation[state];
		const screen = await renderState(state, {
			failure: state === "failed" ? failure : undefined,
		});

		const status = screen.getByRole("status");
		await expect.element(status).toHaveAttribute("data-checkout-state", state);
		if (presentation.status) {
			await expect.element(status).toHaveTextContent(presentation.status);
		}
	},
);

test("ready: Complete Payment requests confirmation", async () => {
	const onconfirm = vi.fn();
	const screen = await renderState("ready", { onconfirm });

	await screen.getByRole("button", { name: "Complete Payment" }).click();

	expect(onconfirm).toHaveBeenCalledTimes(1);
});

test("failed: Try Again and Cancel send the matching events", async () => {
	const onretry = vi.fn();
	const oncancel = vi.fn();
	const screen = await renderState("failed", { failure, onretry, oncancel });

	await expect.element(screen.getByText("Registration Failed")).toBeVisible();
	await expect.element(screen.getByText(failure.message)).toBeVisible();

	await screen.getByRole("button", { name: "Try Again" }).click();
	await screen.getByRole("button", { name: "Cancel" }).click();

	expect(onretry).toHaveBeenCalledTimes(1);
	expect(oncancel).toHaveBeenCalledTimes(1);
});

test("a live actor drives the view through confirmation without creating a new payment intent on retry", async () => {
	let confirmAttempts = 0;
	const confirmPayment = vi.fn(async () => {
		confirmAttempts += 1;
		if (confirmAttempts === 1) throw new Error("Your card was declined.");
	});
	const createPaymentIntent = vi.fn(async () => ({
		clientSecret: "cs_test_1",
		paymentIntentId: "pi_1",
	}));
	const completeRegistration = vi.fn(async () => {});

	const actor = createActor(
		workshopCheckoutMachine.provide({
			actors: {
				loadStripe: fromPromise(async () => {}),
				createPaymentIntent: fromPromise(createPaymentIntent),
				preparePaymentElement: fromPromise(async () => {}),
				confirmPayment: fromPromise(confirmPayment),
				completeRegistration: fromPromise(completeRegistration),
			},
		}),
		{ input: { workshopId: "ws-1", customerId: "cus_1" } },
	).start();
	await waitFor(actor, (snapshot) => snapshot.matches("ready"));

	const screen = await render(WorkshopCheckoutView, {
		state: actor.getSnapshot().value,
		failure: actor.getSnapshot().context.failure,
		workshopTitle: "Longsword fundamentals",
		amount: 2500,
		onconfirm: () => actor.send({ type: "CONFIRM" }),
		onretry: () => actor.send({ type: "RETRY" }),
		oncancel: () => actor.send({ type: "CANCEL" }),
	});
	actor.subscribe((snapshot) => {
		void screen.rerender({
			state: snapshot.value,
			failure: snapshot.context.failure,
		});
	});

	await expect
		.element(screen.getByRole("status"))
		.toHaveAttribute("data-checkout-state", "ready");

	await screen.getByRole("button", { name: "Complete Payment" }).click();
	await expect
		.element(screen.getByRole("status"))
		.toHaveAttribute("data-checkout-state", "failed");
	await expect
		.element(screen.getByRole("status"))
		.toHaveAttribute("data-checkout-stage", "confirmingPayment");

	await screen.getByRole("button", { name: "Try Again" }).click();
	await expect
		.element(screen.getByRole("status"))
		.toHaveAttribute("data-checkout-state", "ready");

	await screen.getByRole("button", { name: "Complete Payment" }).click();
	await expect
		.element(screen.getByRole("status"))
		.toHaveAttribute("data-checkout-state", "succeeded");
	await expect
		.element(screen.getByText("Registration confirmed"))
		.toBeVisible();

	expect(createPaymentIntent).toHaveBeenCalledTimes(1);
	expect(confirmPayment).toHaveBeenCalledTimes(2);
	expect(completeRegistration).toHaveBeenCalledTimes(1);

	actor.stop();
	expect(actor.getSnapshot().status).toBe("stopped");
});
