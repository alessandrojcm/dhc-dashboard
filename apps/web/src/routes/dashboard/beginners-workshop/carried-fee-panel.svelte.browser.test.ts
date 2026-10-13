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
