import { expect, test, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import { formatCivilDate } from "#lib/club-calendar.js";
import { reactivationStartWindow } from "#lib/membership/reactivation-start-window.js";
import { onHostTimeZone } from "#lib/testing/host-time-zone.js";
import ReactivateMembershipModal from "./reactivate-membership-modal.svelte";

// West of UTC, a civil date read as an instant in the reader's zone shows the
// day before; every date below must still read as Phoenix sent it.
onHostTimeZone("America/Los_Angeles");

const savedMethod = {
	id: "pm_sepa_saved",
	last4: "1234",
	bankCode: "37040044",
	country: "DE",
};

// Mirrors GET .../reactivation-preview/amounts data (Dinero minor units).
const amounts = {
	dueToday: { amount: 33000, currency: "EUR", precision: 2 },
	proratedMonthlyPrice: { amount: 1500, currency: "EUR", precision: 2 },
	proratedAnnualPrice: { amount: 31500, currency: "EUR", precision: 2 },
	monthlyFee: { amount: 4200, currency: "EUR", precision: 2 },
	annualFee: { amount: 36000, currency: "EUR", precision: 2 },
	// Phoenix's billing anchors, deliberately unlike anything the browser
	// could work out from the start date or its own clock.
	monthlyBillingStart: "2031-03-01",
	annualBillingStart: "2032-01-07",
};

const fullyLapsedCoverage = {
	monthly: "lapsed" as const,
	annual: "lapsed" as const,
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

test("keeps active monthly coverage unchanged and shows only annual costs", async () => {
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		membershipCoverage: { monthly: "active", annual: "lapsed" },
		amounts: {
			...amounts,
			dueToday: amounts.proratedAnnualPrice,
			proratedMonthlyPrice: { ...amounts.proratedMonthlyPrice, amount: 0 },
			monthlyFee: { ...amounts.monthlyFee, amount: 0 },
		},
		onConfirm: vi.fn(),
	});

	await expect
		.element(
			screen.getByTestId("monthly-coverage").getByText(/already active/i),
		)
		.toBeVisible();
	await expect
		.element(
			screen.getByTestId("annual-coverage").getByText(/will be reactivated/i),
		)
		.toBeVisible();
	await expect.element(screen.getByText("Then annually")).toBeVisible();
	await expect
		.element(screen.getByText("Then monthly"))
		.not.toBeInTheDocument();
});

test("keeps active annual coverage unchanged and shows only monthly costs", async () => {
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		membershipCoverage: { monthly: "lapsed", annual: "active" },
		amounts: {
			...amounts,
			dueToday: amounts.proratedMonthlyPrice,
			proratedAnnualPrice: { ...amounts.proratedAnnualPrice, amount: 0 },
			annualFee: { ...amounts.annualFee, amount: 0 },
		},
		onConfirm: vi.fn(),
	});

	await expect
		.element(
			screen.getByTestId("monthly-coverage").getByText(/will be reactivated/i),
		)
		.toBeVisible();
	await expect
		.element(screen.getByTestId("annual-coverage").getByText(/already active/i))
		.toBeVisible();
	await expect.element(screen.getByText("Then monthly")).toBeVisible();
	await expect
		.element(screen.getByText("Then annually"))
		.not.toBeInTheDocument();
	await expect
		.element(screen.getByRole("group", { name: "Annual fee" }))
		.not.toBeInTheDocument();
});

test("confirms with a date-only ISO start date", async () => {
	const onConfirm = vi.fn();
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		membershipCoverage: fullyLapsedCoverage,
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

// ── ALE-254: pre-confirmation amount preview ─────────────────────────────

// ── ALE-253: annual fee deferral option ──────────────────────────────────

test("defaults to charging the annual fee prorated now", async () => {
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		onConfirm: vi.fn(),
	});

	const proratedNow = screen.getByRole("radio", { name: /charge now/i });
	await expect.element(proratedNow).toBeChecked();

	const deferred = screen.getByRole("radio", {
		name: /defer until next january/i,
	});
	await expect.element(deferred).not.toBeChecked();
});

test("explains deferred billing without exposing Stripe trial mechanics", async () => {
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		onConfirm: vi.fn(),
	});

	await userEvent.click(
		screen.getByRole("radio", { name: /defer until next january/i }),
	);

	await expect
		.element(
			screen.getByText(
				"Nothing is charged today. Annual billing begins next January.",
				{ exact: true },
			),
		)
		.toBeVisible();
	expect(document.body.textContent).not.toContain("free trial");
	expect(document.body.textContent).not.toContain(" – ");
});

test("reports the chosen annual fee mode so amounts can be fetched for it", async () => {
	const onSelectionChange = vi.fn();
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		onSelectionChange,
		onConfirm: vi.fn(),
	});

	expect(onSelectionChange).toHaveBeenCalledWith(
		expect.objectContaining({
			startDate: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/),
			annualFeeMode: "prorated_now",
		}),
	);

	await userEvent.click(
		screen.getByRole("radio", { name: /defer until next january/i }),
	);

	expect(onSelectionChange).toHaveBeenLastCalledWith(
		expect.objectContaining({ annualFeeMode: "deferred_next_year" }),
	);
});

test("confirms with the selected annual fee mode", async () => {
	const onConfirm = vi.fn();
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		onConfirm,
	});

	await userEvent.click(
		screen.getByRole("radio", { name: /defer until next january/i }),
	);

	await userEvent.click(
		screen.getByRole("button", { name: "Reactivate membership" }),
	);

	expect(onConfirm).toHaveBeenCalledWith(
		expect.objectContaining({
			startDate: expect.any(String),
			annualFeeMode: "deferred_next_year",
		}),
	);
});

test("shows the Stripe-computed amounts before confirmation", async () => {
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		amounts,
		onConfirm: vi.fn(),
	});

	const block = screen.getByTestId("reactivation-amounts");
	await expect.element(block).toBeVisible();
	await expect.element(block.getByText("Due today")).toBeVisible();
	await expect.element(block.getByText("€330.00")).toBeVisible();
	await expect
		.element(block.getByText("€15.00 for this month + €315.00 for this year"))
		.toBeVisible();
	await expect.element(block.getByText("Then monthly")).toBeVisible();
	await expect.element(block.getByText("€42.00")).toBeVisible();
	await expect.element(block.getByText("From Sat 1 Mar 2031")).toBeVisible();
	await expect.element(block.getByText("Then annually")).toBeVisible();
	await expect.element(block.getByText("€360.00")).toBeVisible();
	await expect.element(block.getByText("From Wed 7 Jan 2032")).toBeVisible();

	// Amounts never block the operator from confirming.
	await expect
		.element(screen.getByRole("button", { name: "Reactivate membership" }))
		.toBeEnabled();
});

test("separates a future monthly charge from the amount due today", async () => {
	const futureDate = reactivationStartWindow().earliest.add({ days: 10 });
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		initialStartDate: futureDate,
		amounts: {
			...amounts,
			dueToday: amounts.proratedAnnualPrice,
		},
		onConfirm: vi.fn(),
	});

	const block = screen.getByTestId("reactivation-amounts");
	await expect.element(block.getByText("€315.00").first()).toBeVisible();
	await expect
		.element(
			block.getByText(`Due on ${formatCivilDate(futureDate.toString())}`),
		)
		.toBeVisible();
	await expect
		.element(block.getByText("First prorated monthly charge"))
		.toBeVisible();
	await expect.element(block.getByText("€15.00")).toBeVisible();
	await expect
		.element(block.getByText("€15.00 for this month + €315.00 for this year"))
		.not.toBeInTheDocument();
});

test("starts on the window's first day and states the window Phoenix accepts", async () => {
	const onSelectionChange = vi.fn();
	const { earliest, latest } = reactivationStartWindow();
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		onSelectionChange,
		onConfirm: vi.fn(),
	});

	expect(onSelectionChange).toHaveBeenCalledWith(
		expect.objectContaining({ startDate: earliest.toString() }),
	);
	await expect
		.element(
			screen.getByText(
				`Allowed window: ${formatCivilDate(earliest.toString())} to ${formatCivilDate(latest.toString())}.`,
				{ exact: false },
			),
		)
		.toBeVisible();
});

test("shows a calculating state while the amounts are being computed", async () => {
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		isLoadingAmounts: true,
		onConfirm: vi.fn(),
	});

	await expect
		.element(
			screen.getByTestId("reactivation-amounts").getByText(/calculating/i),
		)
		.toBeVisible();
});

test("hides the amounts and keeps the form functional when their preview fails", async () => {
	const onConfirm = vi.fn();
	const screen = await render(ReactivateMembershipModal, {
		open: true,
		isPending: false,
		savedPaymentMethod: savedMethod,
		amounts: null,
		isLoadingAmounts: false,
		onConfirm,
	});

	// Graceful degradation: no amounts block at all, and nothing else breaks.
	expect(
		document.querySelectorAll('[data-testid="reactivation-amounts"]').length,
	).toBe(0);

	const confirm = screen.getByRole("button", { name: "Reactivate membership" });
	await expect.element(confirm).toBeEnabled();
	await userEvent.click(confirm);
	expect(onConfirm).toHaveBeenCalledOnce();
});
