import { expect, test, vi } from "vitest";
import { render } from "vitest-browser-svelte";
import type { AnyActorRef } from "xstate";
import PaymentForm from "./payment-form.svelte";
import type { PageServerData } from "./$types";

function complimentaryData(): PageServerData {
	return {
		state: "paymentReady",
		complimentary: true,
		nextMonthlyBillingDate: new Date("2026-10-01"),
		nextAnnualBillingDate: new Date("2027-01-07"),
	};
}

test("schema validation failure leaves submitting so the invitee can retry", async () => {
	const submit = vi.fn(async () => false);
	const screen = await render(PaymentForm, {
		data: complimentaryData(),
		submit,
	});

	await expect
		.element(screen.getByRole("status"))
		.toHaveAttribute("data-payment-state", "ready");

	await screen.getByRole("button", { name: "Complete signup" }).click();

	await expect
		.element(screen.getByRole("status"))
		.toHaveAttribute("data-payment-state", "failed");
	await expect
		.element(screen.getByRole("button", { name: "Complete signup" }))
		.toBeEnabled();
	await expect
		.element(screen.getByText("Please check the form and try again."))
		.toBeVisible();
});

test("a component-scoped actor is stopped with its component", async () => {
	let actor: AnyActorRef | undefined;
	const screen = await render(PaymentForm, {
		data: complimentaryData(),
		onActor: (next) => {
			actor = next;
		},
	});

	expect(actor).toBeDefined();
	expect(actor?.getSnapshot().status).toBe("active");

	await screen.unmount();

	expect(actor?.getSnapshot().status).toBe("stopped");
});
