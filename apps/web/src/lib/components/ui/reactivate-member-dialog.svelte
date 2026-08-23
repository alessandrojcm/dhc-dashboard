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
	type MembershipReactivateAnnualFeeMode,
} from "@dhc/api-client";
import { page } from "$app/state";
import { toast } from "svelte-sonner";
import ReactivateMembershipModal from "./reactivate-membership-modal.svelte";

/**
 * Self-contained reactivation interaction (ALE-252): fetches the saved SEPA
 * method preview while open, submits the reactivation through the generated
 * mutation options, reports pending/succeeded/declined outcomes as toasts,
 * and reconciles the standard membership queries on success.
 */
let {
	/** Member to reactivate; falsy unmounts nothing but disables queries. */
	memberId,
	open = $bindable(false),
	/** Extra caller-side reconciliation (e.g. SvelteKit load dependencies). */
	onSettled,
}: {
	memberId: string;
	open?: boolean;
	onSettled?: () => Promise<void> | void;
} = $props();

const queryClient = useQueryClient();

// Saved SEPA method shown BEFORE any charge; fetched lazily through the
// generated preview query options while the dialog is open.
const reactivationPreview = createQuery(() => ({
	...membershipReactivationPreviewOptions({
		path: { memberId },
	}),
	enabled: open && memberId !== "",
}));

// The selected start date and annual fee mode are owned by the modal (date
// picker + radio group) and reported up through onSelectionChange so the
// amounts query can key off both (ALE-254, ALE-253).
let previewStartDate = $state<string | null>(null);
let previewAnnualFeeMode =
	$state<MembershipReactivateAnnualFeeMode>("prorated_now");

// Stripe-computed amounts for the chosen selection, fetched only once a
// saved method exists (otherwise the operator gets the billing-portal
// fallback instead). Keyed by startDate AND annualFeeMode, so changing
// either refetches. Failure degrades gracefully: the modal hides amounts
// and keeps the form usable — this query failing must never block a valid
// charge.
const reactivationAmounts = createQuery(() => ({
	...membershipReactivationPreviewAmountsOptions({
		path: { memberId },
		query: {
			startDate: previewStartDate ?? "",
			annualFeeMode: previewAnnualFeeMode,
		},
	}),
	enabled:
		open &&
		memberId !== "" &&
		previewStartDate !== null &&
		Boolean(reactivationPreview.data?.data.savedPaymentMethod),
}));

// Submission error kept inside the modal so the operator can retry without
// losing context; `noSavedMethod` switches it to the billing-portal fallback.
let submitError = $state<{
	detail: string;
	noSavedMethod: boolean;
} | null>(null);

function isOwnProfile(): boolean {
	return page.data.session?.principal?.id === memberId;
}

async function reconcile() {
	await Promise.all([
		queryClient.invalidateQueries({ queryKey: membersListQueryKey() }),
		queryClient.invalidateQueries({
			queryKey: membersShowQueryKey({ path: { memberId } }),
		}),
		queryClient.invalidateQueries({ queryKey: membersAnalyticsQueryKey() }),
		isOwnProfile()
			? queryClient.invalidateQueries({ queryKey: membersMeQueryKey() })
			: Promise.resolve(),
	]);
}

const reactivateMutation = createMutation(() => ({
	...membershipReactivateMutation(),
	onSuccess: async ({ data: result }) => {
		open = false;
		submitError = null;
		if (result.paymentState === "succeeded") {
			toast.success("Membership reactivated.", { position: "top-right" });
		} else if (result.paymentState === "terminal") {
			toast.error(
				"Reactivation submitted, but the bank declined the charge. Use the billing portal to sort out payment.",
				{ position: "top-right", duration: 10000 },
			);
		} else if (
			result.paymentState === "pending" ||
			result.paymentState === "needs_action"
		) {
			toast.info(
				"Awaiting bank confirmation. SEPA direct debits usually settle within a few business days.",
				{ position: "top-right", duration: 10000 },
			);
		}
		await reconcile();
		await onSettled?.();
	},
	onError: (error) => {
		submitError = {
			detail: error.errors?.detail ?? "Failed to reactivate membership",
			noSavedMethod: error.errors?.code === "no_saved_payment_method",
		};
	},
}));

// Manual fallback when the member has no usable saved method (ALE-252):
// the operator opens the Stripe-hosted portal for the member.
const billingPortalMutation = createMutation(() => ({
	...membershipBillingPortalMutation(),
	onSuccess: (response) => {
		window.open(response.data.url, "_blank", "noopener,noreferrer");
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Failed to open billing portal");
	},
}));
</script>

<ReactivateMembershipModal
	bind:open
	isPending={reactivateMutation.isPending}
	isLoadingPreview={reactivationPreview.isPending}
	savedPaymentMethod={reactivationPreview.data?.data.savedPaymentMethod ??
		undefined}
	membershipCoverage={reactivationPreview.data?.data.membershipCoverage}
	amounts={reactivationAmounts.data?.data ?? null}
	isLoadingAmounts={reactivationAmounts.isFetching}
	errorDetail={submitError?.detail ?? null}
	paymentMethodUnavailable={submitError?.noSavedMethod ?? false}
	onOpenBillingPortal={() =>
		billingPortalMutation.mutate({
			path: { memberId },
			body: { returnUrl: window.location.href },
		})}
	onSelectionChange={({ startDate, annualFeeMode }) => {
		previewStartDate = startDate;
		previewAnnualFeeMode = annualFeeMode;
	}}
	onConfirm={({ startDate, annualFeeMode }) => {
		submitError = null;
		reactivateMutation.mutate({
			path: { memberId },
			body: { startDate, annualFeeMode },
		});
	}}
/>
