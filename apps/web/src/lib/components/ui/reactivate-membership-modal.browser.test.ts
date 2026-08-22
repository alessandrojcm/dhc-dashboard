import { expect, test, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import ReactivateMembershipModal from "./reactivate-membership-modal.svelte";

const savedMethod = {
	id: "pm_sepa_saved",
	last4: "1234",
	bankCode: "37040044",
	country: "DE",
};

test("shows the saved SEPA method summary before any charge", async () => {
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		onConfirm: vi.fn(),
	});

	await expect.element(screen.getByText(/ending in 1234/i)).toBeVisible();
	await expect.element(screen.getByText("DE · 37040044")).toBeVisible();
});

test("confirms with a date-only ISO start date", async () => {
	const onConfirm = vi.fn();
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		onConfirm,
	});

	await userEvent.click(
		screen.getByRole("button", { name: "Reactivate membership" }),
	);

	expect(onConfirm).toHaveBeenCalledOnce();
	// SAFETY: the modal's onConfirm contract passes exactly one payload
	// object with a string startDate field.
	const { startDate } = onConfirm.mock.calls[0][0] as {
		startDate: string;
	};
	expect(startDate).toMatch(/^\d{4}-\d{2}-\d{2}$/);
});

test("disables confirmation and offers the billing portal when no method is usable", async () => {
	const onConfirm = vi.fn();
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: null,
		onConfirm,
		onOpenBillingPortal: vi.fn(),
	});

	const confirm = screen.getByRole("button", {
		name: "Reactivate membership",
	});
	await expect.element(confirm).toBeDisabled();

	await expect
		.element(screen.getByText(/no saved SEPA payment details to charge/i))
		.toBeVisible();

	await userEvent.click(
		screen.getByRole("button", { name: /billing portal/i }),
	);
	expect(onConfirm).not.toHaveBeenCalled();
});

test("surfaces submission errors inside the modal", async () => {
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		errorDetail: "Stripe membership reactivation failed",
		onConfirm: vi.fn(),
	});

	await expect
		.element(screen.getByText("Stripe membership reactivation failed"))
		.toBeVisible();
});

test("distinguishes pending settlement from a completed activation while confirming", async () => {
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: true,
		savedPaymentMethod: savedMethod,
		onConfirm: vi.fn(),
	});

	await expect
		.element(screen.getByText(/awaiting bank confirmation/i))
		.toBeVisible();

	const confirm = screen.getByRole("button", {
		name: /confirming/i,
	});
	await expect.element(confirm).toBeDisabled();
});
