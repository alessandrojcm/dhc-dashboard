import type { BeginnersWorkshopCarriedFee } from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
	createCarriedFeePanel,
	type CarriedFeePanelDeps,
} from "./carried-fee-panel.svelte.js";

function fee(
	overrides: Partial<BeginnersWorkshopCarriedFee> = {},
): BeginnersWorkshopCarriedFee {
	return {
		id: "fee-1",
		status: "held",
		origin: "import",
		amountCents: 3500,
		currency: "eur",
		importedPaidText: "Yes",
		stripePaymentIntentId: "pi_1",
		linked: true,
		failedRefund: null,
		availableCommands: ["refund"],
		...overrides,
	};
}

const cleanups: Array<() => void> = [];

afterEach(() => {
	while (cleanups.length) cleanups.pop()?.();
});

function setup(
	current: BeginnersWorkshopCarriedFee,
	deps: CarriedFeePanelDeps = {},
) {
	const queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false },
			mutations: { retry: false },
		},
	});
	const notify = { success: vi.fn(), error: vi.fn() };
	const show = vi.fn(async () => current);

	let panel!: ReturnType<typeof createCarriedFeePanel>;
	cleanups.push(
		$effect.root(() => {
			panel = createCarriedFeePanel(() => "person-1", {
				queryClient,
				notify,
				show,
				...deps,
			});
		}),
	);
	return { panel, notify, show };
}

describe("createCarriedFeePanel (ALE-389)", () => {
	it("loads the person's Carried Fee and offers only Phoenix's commands", async () => {
		const { panel, show } = setup(fee());

		await expect.poll(() => panel.fee?.id).toBe("fee-1");
		expect(show).toHaveBeenCalledWith("person-1");
		expect(panel.can("refund")).toBe(true);
		expect(panel.can("forfeit")).toBe(false);
	});

	it("refunds, says so and refetches the fee", async () => {
		const refund = vi.fn(async () => {});
		const { panel, notify, show } = setup(fee(), { refund });
		await expect.poll(() => panel.fee?.id).toBe("fee-1");

		await expect(panel.refund()).resolves.toEqual({ ok: true });
		expect(refund).toHaveBeenCalledWith("person-1");
		expect(notify.success).toHaveBeenCalledWith(
			"Carried Fee refund requested — they'll pay normally next time.",
		);
		await expect.poll(() => show.mock.calls.length).toBe(2);
	});

	it("follows up a failed refund by its id", async () => {
		const failed = fee({
			failedRefund: {
				id: "refund-9",
				workshopId: null,
				amountCents: 3500,
				currency: "eur",
				reason: "carried_fee_refunded",
				lastError: "card closed",
				failedAt: "2026-10-22T12:00:00Z",
			},
			availableCommands: ["retry", "manual", "forfeit"],
		});
		const retry = vi.fn(async () => {});
		const recordManual = vi.fn(async () => {});
		const forfeit = vi.fn(async () => {});
		const { panel } = setup(failed, { retry, recordManual, forfeit });
		await expect.poll(() => panel.fee?.id).toBe("fee-1");

		await panel.retry();
		await panel.recordManual("  Cash at training ");
		await panel.forfeit();
		expect(retry).toHaveBeenCalledWith("person-1", "refund-9");
		expect(recordManual).toHaveBeenCalledWith(
			"person-1",
			"refund-9",
			"Cash at training",
		);
		expect(forfeit).toHaveBeenCalledWith("person-1", "refund-9");
	});

	it("links an imported fee and returns Phoenix's refusal for the panel to show", async () => {
		const linkPayment = vi.fn(async () => {
			throw {
				errors: {
					detail: "Stripe has no payment with that id",
					code: "stripe_payment_not_found",
				},
			};
		});
		const { panel, notify } = setup(
			fee({ linked: false, availableCommands: ["link_payment"] }),
			{ linkPayment },
		);
		await expect.poll(() => panel.fee?.id).toBe("fee-1");

		await expect(panel.linkPayment(" pi_missing ")).resolves.toEqual({
			ok: false,
			error: "Stripe has no payment with that id",
		});
		expect(linkPayment).toHaveBeenCalledWith("person-1", "pi_missing");
		expect(notify.success).not.toHaveBeenCalled();
	});
});
