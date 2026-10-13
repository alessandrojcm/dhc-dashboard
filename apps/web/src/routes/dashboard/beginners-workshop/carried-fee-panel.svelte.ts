/**
 * ALE-389: one person's Carried Fee on the Waitlist tab — what it is, the
 * payment it refunds against, a refund that failed — and the one command
 * that is the panel's own: link an imported fee to its Stripe payment.
 * Refund credit and the follow-ups to a failed refund (Retry, Record manual
 * refund, Forfeit) are the refund module's (ALE-421, person scope), which
 * invalidates this fee after a success.
 *
 * The Waitlist API cannot know Carried Fees, so this reads and writes through
 * Beginners' Workshops (`beginnersWorkshopCarriedFees.*`). What is offered is
 * Phoenix's `availableCommands` (advisory; Phoenix decides again). Linking
 * invalidates this fee and the Waitlist page's people; its refusal is
 * returned for the panel to show beside the action.
 */
import {
	beginnersWorkshopCarriedFeesLinkPayment,
	beginnersWorkshopCarriedFeesShowOptions,
	type BeginnersWorkshopCarriedFee,
	type BeginnersWorkshopCarriedFeeCommand,
} from "@dhc/api-client";
import {
	createMutation,
	createQuery,
	useQueryClient,
	type QueryClient,
} from "@tanstack/svelte-query";
import { toast } from "svelte-sonner";
import { apiProblem } from "#lib/api-error.js";

export type CarriedFeeNotify = {
	success(message: string): void;
	error(message: string): void;
};

/** Each request defaults to the generated `@dhc/api-client` call. */
export type CarriedFeePanelDeps = {
	queryClient?: QueryClient;
	show?: (waitlistId: string) => Promise<BeginnersWorkshopCarriedFee>;
	linkPayment?: (waitlistId: string, paymentIntentId: string) => Promise<void>;
	notify?: CarriedFeeNotify;
};

export type CarriedFeeOutcome = { ok: true } | { ok: false; error: string };

// What linking makes stale: this fee and the Waitlist page's people (their
// credit and offered commands). Generated keys are
// `[{ _id: "<operation id>", … }]`, and TanStack matches a partial key.
const CARRIED_FEE_QUERIES = [
	[{ _id: "beginnersWorkshopCarriedFeesShow" }],
	[{ _id: "beginnersWorkshopPeopleIndex" }],
];

export function createCarriedFeePanel(
	waitlistId: () => string,
	deps: CarriedFeePanelDeps = {},
) {
	const queryClient = deps.queryClient ?? useQueryClient();
	const notify = deps.notify ?? toast;

	const query = createQuery(
		() => {
			const id = waitlistId();
			const options = beginnersWorkshopCarriedFeesShowOptions({
				path: { waitlistId: id },
			});
			const show = deps.show;
			return {
				...options,
				...(show && { queryFn: async () => ({ data: await show(id) }) }),
				select: (response: { data: BeginnersWorkshopCarriedFee }) =>
					response.data,
			};
		},
		() => queryClient,
	);

	const link = createMutation(
		() => ({
			mutationFn: async (paymentIntentId: string) => {
				const id = waitlistId();
				if (deps.linkPayment) return deps.linkPayment(id, paymentIntentId);
				await beginnersWorkshopCarriedFeesLinkPayment({
					path: { waitlistId: id },
					body: { paymentIntentId },
					throwOnError: true,
				});
			},
			onSuccess: () => notify.success("Linked to the Stripe payment."),
			onSettled: () =>
				Promise.all(
					CARRIED_FEE_QUERIES.map((queryKey) =>
						queryClient.invalidateQueries({ queryKey }),
					),
				),
		}),
		() => queryClient,
	);

	async function linkPayment(
		paymentIntentId: string,
	): Promise<CarriedFeeOutcome> {
		try {
			await link.mutateAsync(paymentIntentId.trim());
			return { ok: true };
		} catch (error) {
			return {
				ok: false,
				error: apiProblem(error)?.detail ?? "Could not link the payment.",
			};
		}
	}

	return {
		/** The person's Carried Fee, until loaded `undefined`. */
		get fee(): BeginnersWorkshopCarriedFee | undefined {
			return query.data;
		},
		get isLoading() {
			return query.isLoading;
		},
		get loadError(): string | null {
			return query.error
				? (apiProblem(query.error)?.detail ??
						"Could not load the workshop credit.")
				: null;
		},
		/** Whether Phoenix offers `kind` for this fee now. */
		can(kind: BeginnersWorkshopCarriedFeeCommand) {
			return query.data?.availableCommands.includes(kind) ?? false;
		},
		get pending() {
			return link.isPending;
		},
		/** Links an imported fee to its Stripe payment (`pi_…`). */
		linkPayment,
	};
}

export type CarriedFeePanel = ReturnType<typeof createCarriedFeePanel>;
