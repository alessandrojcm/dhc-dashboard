import { expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import { createActor, fromPromise } from "xstate";
import {
	paymentMachine,
	paymentMachineStates,
	paymentSubmitPresentation,
	type PaymentFailure,
	type PaymentMachineState,
} from "$lib/invitation-acceptance/payment-machine";
import PaymentSubmit from "./payment-submit.svelte";

const failure: PaymentFailure = {
	message: "Payment could not be completed",
	recoverable: true,
};

async function renderState(
	state: PaymentMachineState,
	overrides: Partial<{
		failure: PaymentFailure | undefined;
		complimentary: boolean;
		onsubmit: () => void;
		onretry: () => void;
	}> = {},
) {
	return await render(PaymentSubmit, {
		state,
		failure: overrides.failure,
		complimentary: overrides.complimentary ?? false,
		verifyAgainHref: "/members/signup/inv-1",
		onsubmit: overrides.onsubmit ?? vi.fn(),
		onretry: overrides.onretry ?? vi.fn(),
	});
}

test.each(paymentMachineStates)(
	"%s renders its intentional submit control",
	async (state) => {
		const presentation = paymentSubmitPresentation[state];
		const screen = await renderState(state, {
			failure: state === "ready" ? undefined : failure,
		});

		const status = screen.getByRole("status");
		await expect.element(status).toHaveAttribute("data-payment-state", state);
		if (presentation.status) {
			await expect.element(status).toHaveTextContent(presentation.status);
		}

		const button = screen.getByRole("button", {
			name: presentation.busy ? undefined : "Sign up",
		});
		if (presentation.disabled) {
			await expect.element(button.first()).toBeDisabled();
		} else {
			await expect.element(button).toBeEnabled();
		}
	},
);

test("ready: clicking Sign up requests a payment without submitting the form natively", async () => {
	const onsubmit = vi.fn();
	const screen = await renderState("ready", { onsubmit });

	await screen.getByRole("button", { name: "Sign up" }).click();

	expect(onsubmit).toHaveBeenCalledTimes(1);
});

test("complimentary invitations label the primary action as completing signup", async () => {
	const screen = await renderState("ready", { complimentary: true });

	await expect
		.element(screen.getByRole("button", { name: "Complete signup" }))
		.toBeVisible();
});

test("failed: shows the failure and lets the invitee try again", async () => {
	const onsubmit = vi.fn();
	const screen = await renderState("failed", { failure, onsubmit });

	await expect.element(screen.getByText("Payment Error")).toBeVisible();
	await expect.element(screen.getByText(failure.message)).toBeVisible();
	await screen.getByRole("button", { name: "Sign up" }).click();
	expect(onsubmit).toHaveBeenCalledTimes(1);
});

test("expired: offers only the way back to verification", async () => {
	const onsubmit = vi.fn();
	const screen = await renderState("expired", {
		failure: {
			message: "Invitation verification has expired. Please verify again.",
			recoverable: false,
		},
		onsubmit,
	});

	await expect.element(screen.getByText("Verify again to continue")).toBeVisible();
	await expect
		.element(screen.getByRole("link", { name: "Verify again" }))
		.toHaveAttribute("href", "/members/signup/inv-1");
	await expect
		.element(screen.getByRole("button", { name: "Sign up" }))
		.toBeDisabled();
	expect(onsubmit).not.toHaveBeenCalled();
});

test("unavailable: retrying reloads the payment form", async () => {
	const onretry = vi.fn();
	const screen = await renderState("unavailable", {
		failure: { message: "stripe.js blocked", recoverable: true },
		onretry,
	});

	await expect.element(screen.getByText("stripe.js blocked")).toBeVisible();
	await screen.getByRole("button", { name: "Try again" }).click();
	expect(onretry).toHaveBeenCalledTimes(1);
});

test("a live actor drives the component through preparing and submitting", async () => {
	const submit = vi.fn();
	const actor = createActor(
		paymentMachine.provide({
			actors: {
				loadPaymentElement: fromPromise(async () => {}),
				preparePayment: fromPromise(async ({ input }) => ({
					confirmationToken: input.complimentary ? undefined : "ctoken_1",
				})),
			},
			actions: { submitPayment: (_, params) => submit(params) },
		}),
		{ input: { complimentary: true } },
	).start();

	const screen = await render(PaymentSubmit, {
		state: actor.getSnapshot().value,
		failure: actor.getSnapshot().context.failure,
		complimentary: true,
		verifyAgainHref: "/members/signup/inv-1",
		onsubmit: () => actor.send({ type: "PAYMENT_REQUESTED" }),
		onretry: () => actor.send({ type: "RETRY_REQUESTED" }),
	});
	actor.subscribe((snapshot) => {
		void screen.rerender({
			state: snapshot.value,
			failure: snapshot.context.failure,
		});
	});

	await screen.getByRole("button", { name: "Complete signup" }).click();

	await expect
		.element(screen.getByRole("status"))
		.toHaveAttribute("data-payment-state", "submitting");
	await expect
		.element(screen.getByRole("status"))
		.toHaveTextContent("Completing your membership");
	expect(submit).toHaveBeenCalledWith({ confirmationToken: undefined });

	actor.stop();
	expect(actor.getSnapshot().status).toBe("stopped");
});
