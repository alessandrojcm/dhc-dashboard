/**
 * The presentational reactivation dialog at its interface (ALE-450): one
 * `reactivationView` phase and the machine's selection in, operator intents
 * out. The protocol itself is asserted in `reactivation-machine.test.ts`; the
 * wiring in `reactivate-member-dialog.browser.test.ts`.
 */
import { expect, test, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import { formatCivilDate } from "#lib/club-calendar.js";
import type {
	MembershipCoverage,
	ReactivationSelection,
	ReactivationView,
} from "#lib/membership/reactivation-machine.js";
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

const fullyLapsedCoverage: MembershipCoverage = {
	monthly: "lapsed",
	annual: "lapsed",
};

function readyView(
	overrides: {
		coverage?: MembershipCoverage;
		submitting?: boolean;
		problem?: string | null;
	} = {},
): ReactivationView {
	return {
		phase: "ready",
		method: savedMethod,
		coverage: overrides.coverage ?? fullyLapsedCoverage,
		submitting: overrides.submitting ?? false,
		problem: overrides.problem ?? null,
	};
}

/**
 * Renders the modal over a selection the test owns, as the machine does:
 * `onSelect` replaces it, so the date picker and radio group stay controlled.
 */
async function renderModal(
	props: {
		view?: ReactivationView;
		selection?: Partial<ReactivationSelection>;
		amounts?: typeof amounts | null;
		isLoadingAmounts?: boolean;
	} = {},
) {
	const intents = {
		onSelect: vi.fn<(selection: ReactivationSelection) => void>(),
		onConfirm: vi.fn(),
		onOpenBillingPortal: vi.fn(),
		onClose: vi.fn(),
	};
	const selection: ReactivationSelection = {
		startDate: reactivationStartWindow().earliest.toString(),
		annualFeeMode: "prorated_now",
		...props.selection,
	};
	const screen = await render(ReactivateMembershipModal, {
		view: props.view ?? readyView(),
		selection,
		amounts: props.amounts,
		isLoadingAmounts: props.isLoadingAmounts,
		...intents,
		onSelect: (next) => {
			intents.onSelect(next);
			void screen.rerender({ selection: next });
		},
	});
	return { screen, ...intents };
}

test("shows the saved SEPA method summary before any charge", async () => {
	const { screen } = await renderModal();

	await expect.element(screen.getByText(/ending in 1234/i)).toBeVisible();
	await expect.element(screen.getByText("DE · 37040044")).toBeVisible();
});

test("says it is checking the saved method while the lookup runs", async () => {
	const { screen } = await renderModal({
		view: { phase: "lookingUp", coverage: fullyLapsedCoverage },
	});

	await expect
		.element(screen.getByText(/checking saved payment method/i))
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Reactivate membership" }))
		.toBeDisabled();
});

test("keeps active monthly coverage unchanged and shows only annual costs", async () => {
	const { screen } = await renderModal({
		view: readyView({ coverage: { monthly: "active", annual: "lapsed" } }),
		amounts: {
			...amounts,
			dueToday: amounts.proratedAnnualPrice,
			proratedMonthlyPrice: { ...amounts.proratedMonthlyPrice, amount: 0 },
			monthlyFee: { ...amounts.monthlyFee, amount: 0 },
		},
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
	const { screen } = await renderModal({
		view: readyView({ coverage: { monthly: "lapsed", annual: "active" } }),
		amounts: {
			...amounts,
			dueToday: amounts.proratedMonthlyPrice,
			proratedAnnualPrice: { ...amounts.proratedAnnualPrice, amount: 0 },
			annualFee: { ...amounts.annualFee, amount: 0 },
		},
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

test("offers nothing to confirm when both subscriptions are already active", async () => {
	const { screen } = await renderModal({
		view: readyView({ coverage: { monthly: "active", annual: "active" } }),
	});

	await expect
		.element(screen.getByText(/nothing will be recreated or charged/i))
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: "Reactivate membership" }))
		.toBeDisabled();
});

test("asks the machine to confirm", async () => {
	const { screen, onConfirm } = await renderModal();

	await userEvent.click(
		screen.getByRole("button", { name: "Reactivate membership" }),
	);

	expect(onConfirm).toHaveBeenCalledOnce();
});

test("disables confirmation and offers the billing portal when no method is usable", async () => {
	const { screen, onConfirm, onOpenBillingPortal } = await renderModal({
		view: {
			phase: "noSavedMethod",
			openingPortal: false,
			coverage: fullyLapsedCoverage,
		},
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
	expect(onOpenBillingPortal).toHaveBeenCalledOnce();
	expect(onConfirm).not.toHaveBeenCalled();
});

test("holds the billing portal button while its session is being created", async () => {
	const { screen } = await renderModal({
		view: {
			phase: "noSavedMethod",
			openingPortal: true,
			coverage: fullyLapsedCoverage,
		},
	});

	await expect
		.element(screen.getByRole("button", { name: /billing portal/i }))
		.toBeDisabled();
});

test("tells a failed lookup apart from a missing saved method", async () => {
	const { screen } = await renderModal({
		view: { phase: "lookupFailed", coverage: fullyLapsedCoverage },
	});

	await expect
		.element(screen.getByText("Could not check the saved payment method"))
		.toBeVisible();
	await expect
		.element(screen.getByRole("button", { name: /billing portal/i }))
		.not.toBeInTheDocument();
	await expect
		.element(screen.getByRole("button", { name: "Reactivate membership" }))
		.toBeDisabled();
});

test("surfaces submission errors inside the modal", async () => {
	const { screen } = await renderModal({
		view: readyView({ problem: "Stripe membership reactivation failed" }),
	});

	await expect
		.element(screen.getByText("Stripe membership reactivation failed"))
		.toBeVisible();
});

test("distinguishes pending settlement from a completed activation while confirming", async () => {
	const { screen, onClose } = await renderModal({
		view: readyView({ submitting: true }),
	});

	await expect
		.element(screen.getByText(/awaiting bank confirmation/i))
		.toBeVisible();

	const confirm = screen.getByRole("button", {
		name: /confirming/i,
	});
	await expect.element(confirm).toBeDisabled();
	await expect
		.element(screen.getByRole("button", { name: "Cancel" }))
		.toBeDisabled();
	expect(onClose).not.toHaveBeenCalled();
});

test("asks to close when the operator cancels", async () => {
	const { screen, onClose } = await renderModal();

	await userEvent.click(screen.getByRole("button", { name: "Cancel" }));

	expect(onClose).toHaveBeenCalledOnce();
});

// ── ALE-253: annual fee deferral option ──────────────────────────────────

test("renders the machine's annual fee mode", async () => {
	const { screen } = await renderModal();

	const proratedNow = screen.getByRole("radio", { name: /charge now/i });
	await expect.element(proratedNow).toBeChecked();

	const deferred = screen.getByRole("radio", {
		name: /defer until next january/i,
	});
	await expect.element(deferred).not.toBeChecked();
});

test("explains deferred billing without exposing Stripe trial mechanics", async () => {
	const { screen } = await renderModal();

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

test("reports the chosen annual fee mode with the selected start date", async () => {
	const { screen, onSelect } = await renderModal();
	const { earliest } = reactivationStartWindow();

	await userEvent.click(
		screen.getByRole("radio", { name: /defer until next january/i }),
	);

	expect(onSelect).toHaveBeenLastCalledWith({
		startDate: earliest.toString(),
		annualFeeMode: "deferred_next_year",
	});
	await expect
		.element(screen.getByRole("radio", { name: /defer until next january/i }))
		.toBeChecked();
});

// ── ALE-254: pre-confirmation amount preview ─────────────────────────────

test("shows the Stripe-computed amounts before confirmation", async () => {
	const { screen } = await renderModal({ amounts });

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
	const { screen } = await renderModal({
		selection: { startDate: futureDate.toString() },
		amounts: {
			...amounts,
			dueToday: amounts.proratedAnnualPrice,
		},
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

test("states the window Phoenix accepts", async () => {
	const { earliest, latest } = reactivationStartWindow();
	const { screen } = await renderModal();

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
	const { screen } = await renderModal({ isLoadingAmounts: true });

	await expect
		.element(
			screen.getByTestId("reactivation-amounts").getByText(/calculating/i),
		)
		.toBeVisible();
});

test("hides the amounts and keeps the form functional when their preview fails", async () => {
	const { screen, onConfirm } = await renderModal({
		amounts: null,
		isLoadingAmounts: false,
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
