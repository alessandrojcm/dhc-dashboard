/**
 * ALE-389: one person's Carried Fee on the Waitlist tab — what it is, the
 * payment it refunds against, a refund that failed — and the commands on it:
 * Refund Carried Fee, link an imported fee to its Stripe payment, and the
 * follow-ups to a failed refund (Retry, Record manual refund, Forfeit).
 *
 * The Waitlist API cannot know Carried Fees, so this reads and writes through
 * Beginners' Workshops (`beginnersWorkshopCarriedFees.*`). What is offered is
 * Phoenix's `availableCommands` (advisory; Phoenix decides again). Every
 * write invalidates this fee and the Waitlist page's Carried Fee statuses.
 * A command's refusal is returned for the panel to show beside the action.
 */
import {
	beginnersWorkshopCarriedFeesForfeit,
	beginnersWorkshopCarriedFeesLinkPayment,
	beginnersWorkshopCarriedFeesRecordManualRefund,
	beginnersWorkshopCarriedFeesRefund,
	beginnersWorkshopCarriedFeesRetryRefund,
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
	refund?: (waitlistId: string) => Promise<void>;
	linkPayment?: (waitlistId: string, paymentIntentId: string) => Promise<void>;
	retry?: (waitlistId: string, refundId: string) => Promise<void>;
	recordManual?: (
		waitlistId: string,
		refundId: string,
		note: string,
	) => Promise<void>;
	forfeit?: (waitlistId: string, refundId: string) => Promise<void>;
	notify?: CarriedFeeNotify;
};

export type CarriedFeeOutcome = { ok: true } | { ok: false; error: string };

type Command = {
	kind: BeginnersWorkshopCarriedFeeCommand;
	paymentIntentId?: string;
	note?: string;
};

const DONE = {
	refund: "Carried Fee refund requested — they'll pay normally next time.",
	link_payment: "Linked to the Stripe payment.",
	retry: "Refund sent to Stripe again.",
	manual: "Recorded as refunded (manual) — no email sent.",
	forfeit: "Carried Fee forfeited — no email sent.",
} satisfies Record<BeginnersWorkshopCarriedFeeCommand, string>;

const FALLBACK = {
	refund: "Could not refund the Carried Fee.",
	link_payment: "Could not link the payment.",
	retry: "Could not retry the refund.",
	manual: "Could not record the manual refund.",
	forfeit: "Could not forfeit the Carried Fee.",
} satisfies Record<BeginnersWorkshopCarriedFeeCommand, string>;

// What every Carried Fee write makes stale: this fee and the Waitlist page's
// statuses. Generated keys are `[{ _id: "<operation id>", … }]`, and
// TanStack matches a partial key.
const CARRIED_FEE_QUERIES = [
	[{ _id: "beginnersWorkshopCarriedFeesShow" }],
	[{ _id: "beginnersWorkshopCarriedFeesIndex" }],
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

	// One request per command, injectable for tests. Phoenix's answer is not
	// needed: every write refetches the fee.
	async function request(
		command: Command,
		fee: BeginnersWorkshopCarriedFee,
	): Promise<void> {
		const id = waitlistId();
		const refundId = fee.failedRefund?.id ?? "";
		const note = command.note?.trim() ?? "";
		switch (command.kind) {
			case "refund":
				if (deps.refund) return deps.refund(id);
				await beginnersWorkshopCarriedFeesRefund({
					path: { waitlistId: id },
					throwOnError: true,
				});
				return;
			case "link_payment": {
				const paymentIntentId = command.paymentIntentId?.trim() ?? "";
				if (deps.linkPayment) return deps.linkPayment(id, paymentIntentId);
				await beginnersWorkshopCarriedFeesLinkPayment({
					path: { waitlistId: id },
					body: { paymentIntentId },
					throwOnError: true,
				});
				return;
			}
			case "retry":
				if (deps.retry) return deps.retry(id, refundId);
				await beginnersWorkshopCarriedFeesRetryRefund({
					path: { waitlistId: id, refundId },
					throwOnError: true,
				});
				return;
			case "manual":
				if (deps.recordManual) return deps.recordManual(id, refundId, note);
				await beginnersWorkshopCarriedFeesRecordManualRefund({
					path: { waitlistId: id, refundId },
					body: note ? { note } : {},
					throwOnError: true,
				});
				return;
			case "forfeit":
				if (deps.forfeit) return deps.forfeit(id, refundId);
				await beginnersWorkshopCarriedFeesForfeit({
					path: { waitlistId: id, refundId },
					throwOnError: true,
				});
				return;
		}
	}

	const command = createMutation(
		() => ({
			mutationFn: (variables: Command) => {
				const fee = query.data;
				if (!fee) throw new Error("The Carried Fee is not loaded yet.");
				return request(variables, fee);
			},
			onSuccess: (_done: void, variables: Command) =>
				notify.success(DONE[variables.kind]),
			onSettled: () =>
				Promise.all(
					CARRIED_FEE_QUERIES.map((queryKey) =>
						queryClient.invalidateQueries({ queryKey }),
					),
				),
		}),
		() => queryClient,
	);

	async function run(variables: Command): Promise<CarriedFeeOutcome> {
		try {
			await command.mutateAsync(variables);
			return { ok: true };
		} catch (error) {
			return {
				ok: false,
				error: apiProblem(error)?.detail ?? FALLBACK[variables.kind],
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
				? (apiProblem(query.error)?.detail ?? "Could not load the Carried Fee.")
				: null;
		},
		/** Whether Phoenix offers `kind` for this fee now. */
		can(kind: BeginnersWorkshopCarriedFeeCommand) {
			return query.data?.availableCommands.includes(kind) ?? false;
		},
		get pending() {
			return command.isPending;
		},
		refund: () => run({ kind: "refund" }),
		linkPayment: (paymentIntentId: string) =>
			run({ kind: "link_payment", paymentIntentId }),
		retry: () => run({ kind: "retry" }),
		recordManual: (note: string) => run({ kind: "manual", note }),
		forfeit: () => run({ kind: "forfeit" }),
	};
}

export type CarriedFeePanel = ReturnType<typeof createCarriedFeePanel>;
