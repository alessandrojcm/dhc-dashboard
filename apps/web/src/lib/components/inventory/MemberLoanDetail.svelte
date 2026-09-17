<script lang="ts">
import {
	createMutation,
	createQuery,
	useQueryClient,
} from "@tanstack/svelte-query";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Label } from "$lib/components/ui/label";
import { Textarea } from "$lib/components/ui/textarea";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Skeleton } from "$lib/components/ui/skeleton";
import { CalendarDays, MapPin, RefreshCw, TriangleAlert } from "@lucide/svelte";
import { toast } from "svelte-sonner";
import {
	inventoryCatalogShowItemQueryKey,
	inventoryMemberLoansCancelMutation,
	inventoryMemberLoansListQueryKey,
	inventoryMemberLoansShowOptions,
	inventoryMemberLoansShowQueryKey,
} from "@dhc/api-client";

// ALE-288 loan detail (ALE-280 stories 59–60): approval notifications land
// here — approved dates plus the container path for collection — and the
// member cancels before checkout from this same view. After checkout,
// release is the operator's return command.

const queryClient = useQueryClient();
let { loanId }: { loanId: string } = $props();

const loanQuery = createQuery(() => ({
	...inventoryMemberLoansShowOptions({ path: { loanId } }),
	select: (response) => response.data,
}));

let cancelNote = $state("");

const cancellable = $derived(
	loanQuery.data?.status === "requested" ||
		loanQuery.data?.status === "approved",
);

const cancelMutation = createMutation(() => ({
	...inventoryMemberLoansCancelMutation(),
	onSuccess: () => {
		cancelNote = "";
		const itemSlug = loanQuery.data?.itemSlug;
		queryClient.invalidateQueries({
			queryKey: inventoryMemberLoansShowQueryKey({ path: { loanId } }),
		});
		queryClient.invalidateQueries({
			queryKey: inventoryMemberLoansListQueryKey(),
		});
		if (itemSlug) {
			queryClient.invalidateQueries({
				queryKey: inventoryCatalogShowItemQueryKey({
					path: { slugOrId: itemSlug },
				}),
			});
		}
		toast.success("Loan cancelled — the item is available again.");
	},
	onError: (error) => {
		// SAFETY: Phoenix renders loan conflicts as `{ errors: { detail, code } }`
		// (see InventoryMemberLoanConflictError); only `code` is read, for branching.
		const code = (error.errors as { code?: string } | undefined)?.code;
		if (code === "not_cancellable") {
			toast.error("This loan can no longer be cancelled.");
		} else {
			toast.error(error.errors?.detail ?? "Couldn't cancel the loan.");
		}
	},
}));

function statusLabel(status: string): string {
	return status.replace("_", " ");
}

function formatDate(iso: string | null): string {
	if (!iso) return "—";
	return iso.slice(0, 10);
}
</script>

<svelte:head>
	<title>
		{loanQuery.data
			? `${loanQuery.data.itemLabel} | My loans`
			: "My loans | Dublin HEMA Club"}
	</title>
</svelte:head>

{#if loanQuery.isPending}
	<div class="space-y-3" aria-label="Loading loan">
		<Skeleton class="h-9 w-2/3" />
		<Skeleton class="h-5 w-1/3" />
		<div class="rounded-2xl border border-border bg-card p-4">
			<Skeleton class="h-5 w-full" />
			<Skeleton class="mt-2 h-5 w-2/3" />
		</div>
	</div>
{:else if loanQuery.isError}
	<Alert variant="destructive">
		<AlertDescription
			class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"
		>
			<span>
				{loanQuery.error.errors?.detail ?? "We couldn't load this loan."}
			</span>
			<Button
				variant="outline"
				size="sm"
				class="min-h-10"
				onclick={() => loanQuery.refetch()}
			>
				<RefreshCw aria-hidden="true" />
				Try again
			</Button>
		</AlertDescription>
	</Alert>
{:else if loanQuery.data}
	{@const loan = loanQuery.data}
	<section aria-labelledby="loan-heading" class="space-y-5">
		<div class="border-b pb-5 pr-10">
			<div class="flex items-start justify-between gap-2">
				<div class="min-w-0">
					<p
						class="text-xs font-semibold uppercase tracking-[0.16em] text-primary"
					>
						Loan details
					</p>
					<h1 id="loan-heading" class="mt-1 font-heading text-2xl font-bold">
						{loan.itemLabel}
					</h1>
				</div>
				<div class="flex shrink-0 flex-col items-end gap-1.5">
					<Badge variant={cancellable ? "secondary" : "outline"}>
						{statusLabel(loan.status)}
					</Badge>
					{#if loan.overdue}
						<Badge variant="destructive" class="gap-1">
							<TriangleAlert class="size-3" aria-hidden="true" />
							Overdue
						</Badge>
					{/if}
				</div>
			</div>
			<p class="mt-2 font-mono text-xs text-muted-foreground">
				ID {loan.itemSlug}
			</p>
		</div>

		<article class="inventory-panel p-5">
			<div class="flex items-center gap-2">
				<CalendarDays class="size-5 text-primary" aria-hidden="true" />
				<h2 class="font-semibold">Dates</h2>
			</div>
			<dl class="mt-3 space-y-2 text-sm">
				<div class="flex items-baseline justify-between gap-3">
					<dt class="text-muted-foreground">Requested</dt>
					<dd class="font-medium">
						{formatDate(loan.requestedStartOn)} → {formatDate(
							loan.requestedDueOn,
						)}
					</dd>
				</div>
				{#if loan.approvedStartOn || loan.approvedDueOn}
					<div class="flex items-baseline justify-between gap-3">
						<dt class="text-muted-foreground">Approved</dt>
						<dd class="font-medium">
							{formatDate(loan.approvedStartOn)} → {formatDate(
								loan.approvedDueOn,
							)}
						</dd>
					</div>
				{/if}
				{#if loan.checkedOutAt}
					<div class="flex items-baseline justify-between gap-3">
						<dt class="text-muted-foreground">Collected</dt>
						<dd class="font-medium">{formatDate(loan.checkedOutAt)}</dd>
					</div>
				{/if}
				{#if loan.returnedAt}
					<div class="flex items-baseline justify-between gap-3">
						<dt class="text-muted-foreground">Returned</dt>
						<dd class="font-medium">{formatDate(loan.returnedAt)}</dd>
					</div>
				{/if}
			</dl>
		</article>

		{#if loan.containerPath}
			<p
				class="flex gap-2 rounded-2xl border border-primary/30 bg-primary/5 p-4 text-sm"
			>
				<MapPin class="size-4 shrink-0 text-primary" aria-hidden="true" />
				<span>
					<strong>Collect from {loan.containerPath}.</strong> Confirm the labelled
					item before checkout.
				</span>
			</p>
		{/if}

		{#if loan.requestNote}
			<article class="rounded-2xl border border-border bg-card p-4 text-sm">
				<h2 class="font-semibold">Your note</h2>
				<p class="mt-1 text-muted-foreground">{loan.requestNote}</p>
			</article>
		{/if}

		{#if loan.decisionNote}
			<article class="rounded-2xl border border-border bg-card p-4 text-sm">
				<h2 class="font-semibold">Operator note</h2>
				<p class="mt-1 text-muted-foreground">{loan.decisionNote}</p>
			</article>
		{/if}

		{#if cancellable}
			<div class="rounded-2xl border border-border bg-muted/40 p-4">
				<h2 class="font-semibold">Cancel this loan</h2>
				<p class="mt-1 text-sm text-muted-foreground">
					Cancelling releases the item immediately. Tapping twice is safe — a
					repeat cancel is a no-op.
				</p>
				<form
					onsubmit={(e) => {
						e.preventDefault();
						cancelMutation.mutate({
							path: { loanId: loan.id },
							body: cancelNote.trim() ? { note: cancelNote.trim() } : {},
						});
					}}
				>
					<div class="mt-3">
						<Label for="cancel-note" class="text-sm font-medium">
							Reason
							<span class="font-normal text-muted-foreground">(optional)</span>
						</Label>
						<Textarea
							id="cancel-note"
							class="mt-1"
							rows={2}
							maxlength={500}
							placeholder="Plans changed"
							bind:value={cancelNote}
						/>
					</div>
					{#if cancelMutation.isError}
						<p class="mt-3 text-sm text-destructive" aria-live="polite">
							{(cancelMutation.error.errors as { detail?: string } | undefined)
								?.detail ?? "Couldn't cancel the loan."}
						</p>
					{/if}
					<Button
						type="submit"
						variant="outline"
						class="mt-4 min-h-12 w-full text-base"
						disabled={cancelMutation.isPending}
					>
						{cancelMutation.isPending ? "Cancelling…" : "Cancel loan"}
					</Button>
				</form>
			</div>
		{:else if loan.status === "checked_out"}
			<p
				class="rounded-2xl border border-border bg-muted/40 p-4 text-sm text-muted-foreground"
			>
				This item is with you — hand it back to a quartermaster to complete the
				return.
			</p>
		{/if}
	</section>
{/if}
