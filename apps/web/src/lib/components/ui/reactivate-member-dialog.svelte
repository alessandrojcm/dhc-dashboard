<script lang="ts">
import {
	createMutation,
	createQuery,
	useQueryClient,
} from "@tanstack/svelte-query";
import {
	membersAnalyticsQueryKey,
	membersListQueryKey,
	membersMeQueryKey,
	membersShowQueryKey,
	membershipBillingPortalMutation,
	membershipReactivateMutation,
	membershipReactivationPreviewAmountsOptions,
	membershipReactivationPreviewOptions,
} from "@dhc/api-client";
import { useMachine } from "@xstate/svelte";
import { fromPromise } from "xstate";
import { page } from "$app/state";
import { untrack } from "svelte";
import { toast } from "svelte-sonner";
import {
	reactivationMachine,
	reactivationView,
	type ReactivationOutcome,
} from "#lib/membership/reactivation-machine.js";
import { reactivationStartWindow } from "#lib/membership/reactivation-start-window.js";
import ReactivateMembershipModal from "./reactivate-membership-modal.svelte";

/**
 * One reactivation dialog for one member (ALE-252, ALE-450). Mount it only
 * while the dialog is open, keyed by the member: it runs its own
 * `reactivationMachine` actor, which stops when this unmounts, so a late
 * answer for a previous member can never reach a replacement.
 *
 * TanStack Query owns every read and the cache: the machine's actors are the
 * generated preview query and mutations, and the amounts preview is a query
 * keyed off the machine's selection.
 */
let {
	memberId,
	/** The dialog finished (an outcome, or dismissed): unmount it. */
	onClose,
	/**
	 * Extra caller-side reconciliation (e.g. SvelteKit load dependencies) for
	 * the member reactivated; it may run after this dialog unmounted.
	 */
	onSettled,
}: {
	memberId: string;
	onClose: () => void;
	onSettled?: (memberId: string) => Promise<void> | void;
} = $props();

const queryClient = useQueryClient();
// Read once: the machine is this member's, and so is everything below.
const member = untrack(() => memberId);
// One reading for the machine's initial start date and the date picker.
const startWindow = reactivationStartWindow();

const reactivateMutation = createMutation(() => membershipReactivateMutation());
const billingPortalMutation = createMutation(() =>
	membershipBillingPortalMutation(),
);

const OUTCOME_TOASTS = {
	succeeded: () =>
		toast.success("Membership reactivated.", { position: "top-right" }),
	terminal: () =>
		toast.error(
			"Reactivation submitted, but the bank declined the charge. Use the billing portal to sort out payment.",
			{ position: "top-right", duration: 10000 },
		),
	pending: awaitingBank,
	needs_action: awaitingBank,
} satisfies Record<ReactivationOutcome, () => void>;

function awaitingBank() {
	toast.info(
		"Awaiting bank confirmation. SEPA direct debits usually settle within a few business days.",
		{ position: "top-right", duration: 10000 },
	);
}

/**
 * Runs as the dialog closes and outlives this component on purpose: the
 * reactivation already happened, so its reads go stale either way.
 */
async function reconcile(
	reactivated: string,
	settled: ((memberId: string) => Promise<void> | void) | undefined,
) {
	const ownProfile = page.data.session?.principal?.id === reactivated;
	await Promise.all([
		queryClient.invalidateQueries({ queryKey: membersListQueryKey() }),
		queryClient.invalidateQueries({
			queryKey: membersShowQueryKey({ path: { memberId: reactivated } }),
		}),
		queryClient.invalidateQueries({ queryKey: membersAnalyticsQueryKey() }),
		ownProfile
			? queryClient.invalidateQueries({ queryKey: membersMeQueryKey() })
			: Promise.resolve(),
	]);
	await settled?.(reactivated);
}

const { snapshot, send } = useMachine(
	reactivationMachine.provide({
		actors: {
			lookUpMethod: fromPromise(async ({ input, signal }) => {
				const options = membershipReactivationPreviewOptions({
					path: { memberId: input.memberId },
				});
				// Closing mid-lookup cancels the request the query client runs.
				signal.addEventListener("abort", () => {
					void queryClient.cancelQueries({ queryKey: options.queryKey });
				});
				const response = await queryClient.fetchQuery(options);
				return response.data;
			}),
			reactivate: fromPromise(async ({ input }) => {
				const response = await reactivateMutation.mutateAsync({
					path: { memberId: input.memberId },
					body: input.selection,
				});
				return response.data;
			}),
			openBillingPortal: fromPromise(async ({ input }) => {
				const response = await billingPortalMutation.mutateAsync({
					path: { memberId: input.memberId },
					body: { returnUrl: window.location.href },
				});
				return response.data;
			}),
		},
		actions: {
			report: (_, outcome) => OUTCOME_TOASTS[outcome](),
			reconcile: ({ context }) => {
				void reconcile(context.memberId, onSettled);
			},
			showPortal: (_, { url }) => {
				window.open(url, "_blank", "noopener,noreferrer");
			},
			portalFailed: (_, { detail }) => {
				toast.error(detail);
			},
			close: () => onClose(),
		},
	}),
	{ input: { memberId: member, startDate: startWindow.earliest.toString() } },
);

const view = $derived(reactivationView($snapshot));
const selection = $derived($snapshot.context.selection);

// Stripe-computed amounts for the chosen selection, fetched only once a
// saved method exists (otherwise the operator gets the billing-portal
// fallback instead). Keyed by startDate AND annualFeeMode, so changing
// either refetches. Failure degrades gracefully: the modal hides amounts and
// keeps the form usable, so this query failing never blocks a valid charge.
const reactivationAmounts = createQuery(() => ({
	...membershipReactivationPreviewAmountsOptions({
		path: { memberId: member },
		query: {
			startDate: selection.startDate,
			annualFeeMode: selection.annualFeeMode,
		},
	}),
	enabled: view.phase === "ready",
}));
</script>

<ReactivateMembershipModal
	{view}
	{selection}
	{startWindow}
	amounts={reactivationAmounts.data?.data ?? null}
	isLoadingAmounts={reactivationAmounts.isFetching}
	onSelect={(next) => send({ type: "SELECT", ...next })}
	onConfirm={() => send({ type: "CONFIRM" })}
	onOpenBillingPortal={() => send({ type: "OPEN_PORTAL" })}
	onClose={() => send({ type: "CLOSE" })}
/>
