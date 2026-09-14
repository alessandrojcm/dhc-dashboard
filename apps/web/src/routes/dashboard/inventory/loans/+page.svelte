<script lang="ts">
import { createMutation, createQuery } from "@tanstack/svelte-query";
import {
	type InventoryOperatorLoan,
	inventoryOperatorLoanQueueShowOptions,
	inventoryOperatorLoansApproveMutation,
	inventoryOperatorLoansCancelMutation,
	inventoryOperatorLoansCheckoutMutation,
	inventoryOperatorLoansEditDatesMutation,
	inventoryOperatorLoansRejectMutation,
	inventoryOperatorLoansReturnMutation,
} from "@dhc/api-client";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import { Textarea } from "$lib/components/ui/textarea";
import { apiErrorMessage } from "$lib/server/api-error";
import {
	CalendarClock,
	ClipboardCheck,
	ClipboardList,
	PackageCheck,
	RefreshCw,
	TriangleAlert,
	Wrench,
} from "@lucide/svelte";
import { toast } from "svelte-sonner";

let selected = $state<InventoryOperatorLoan | undefined>();
let selectedReadyForCheckout = $state(false);
let startsOn = $state("");
let dueOn = $state("");
let note = $state("");

const queueQuery = createQuery(() => ({
	...inventoryOperatorLoanQueueShowOptions(),
	select: (response) => response.data,
}));

function choose(loan: InventoryOperatorLoan, readyForCheckout = false) {
	selected = loan;
	selectedReadyForCheckout = readyForCheckout;
	startsOn = loan.approvedStartOn ?? loan.requestedStartOn;
	dueOn = loan.approvedDueOn ?? loan.requestedDueOn;
	note = "";
}

function refresh() {
	selected = undefined;
	void queueQuery.refetch();
}

function mutationOptions(success: string, fallback: string) {
	return {
		onSuccess: () => {
			toast.success(success);
			refresh();
		},
		onError: (cause: unknown) => toast.error(apiErrorMessage(cause, fallback)),
	};
}

const approve = createMutation(() => ({
	...inventoryOperatorLoansApproveMutation(),
	...mutationOptions("Loan approved", "Could not approve this request"),
}));
const reject = createMutation(() => ({
	...inventoryOperatorLoansRejectMutation(),
	...mutationOptions("Request rejected", "Could not reject this request"),
}));
const cancel = createMutation(() => ({
	...inventoryOperatorLoansCancelMutation(),
	...mutationOptions("Loan cancelled", "Could not cancel this loan"),
}));
const checkout = createMutation(() => ({
	...inventoryOperatorLoansCheckoutMutation(),
	...mutationOptions("Checkout recorded", "Could not record checkout"),
}));
const returnLoan = createMutation(() => ({
	...inventoryOperatorLoansReturnMutation(),
	...mutationOptions("Return recorded", "Could not record return"),
}));
const editDates = createMutation(() => ({
	...inventoryOperatorLoansEditDatesMutation(),
	...mutationOptions("Loan dates updated", "Could not update loan dates"),
}));

function formatDate(value: string | null) {
	return value?.slice(0, 10) ?? "—";
}

function shortPrincipal(id: string) {
	return id.slice(0, 8);
}

function pending(...mutations: Array<{ isPending: boolean }>) {
	return mutations.some((mutation) => mutation.isPending);
}
</script>

{#snippet loanCard(
	loan: InventoryOperatorLoan,
	kind: "request" | "handover" | "return",
	readyForCheckout = false,
)}
	<article class="rounded-2xl border border-border bg-card p-4 shadow-sm">
		<div class="flex items-start justify-between gap-3">
			<div class="min-w-0">
				<div class="flex flex-wrap items-center gap-2">
					<h3 class="font-semibold">{loan.itemLabel}</h3>
					<Badge variant="outline">{loan.itemSlug}</Badge>
				</div>
				<p class="mt-1 text-sm text-muted-foreground">
					Borrower {shortPrincipal(loan.borrowerPrincipalId)} · {formatDate(
						loan.approvedStartOn ?? loan.requestedStartOn,
					)} → {formatDate(loan.approvedDueOn ?? loan.requestedDueOn)}
				</p>
				{#if loan.containerPath}<p class="mt-2 text-sm">
						<span class="font-medium">Collect from:</span>
						{loan.containerPath}
					</p>{/if}
				{#if loan.requestNote}<p
						class="mt-2 rounded-lg bg-muted/60 px-3 py-2 text-sm"
					>
						{loan.requestNote}
					</p>{/if}
			</div>
			{#if loan.overdue}<Badge variant="destructive" class="shrink-0 gap-1"
					><TriangleAlert class="size-3" />Overdue</Badge
				>{/if}
		</div>
		<div class="mt-4 flex flex-wrap gap-2">
			<Button class="min-h-11" onclick={() => choose(loan, readyForCheckout)}>
				{kind === "request"
					? "Review request"
					: kind === "handover"
						? "Record handover"
						: "Record return"}
			</Button>
		</div>
	</article>
{/snippet}

{#snippet bucket(
	title: string,
	description: string,
	count: number,
	icon: typeof ClipboardList,
)}
	{@const Icon = icon}
	<div class="flex items-center gap-3 border-b border-border/70 pb-3">
		<div class="rounded-xl bg-primary/10 p-2 text-primary">
			<Icon class="size-5" />
		</div>
		<div class="min-w-0 flex-1">
			<h2 class="font-heading text-xl font-bold">{title}</h2>
			<p class="text-sm text-muted-foreground">{description}</p>
		</div>
		<Badge variant={count ? "secondary" : "outline"} class="text-sm"
			>{count}</Badge
		>
	</div>
{/snippet}

<svelte:head><title>Loan queue | Dublin HEMA Club</title></svelte:head>

<div class="mx-auto max-w-6xl space-y-6 px-4 py-6 sm:px-6 sm:py-8">
	<header
		class="flex flex-col gap-4 border-b border-border/80 pb-5 sm:flex-row sm:items-end sm:justify-between"
	>
		<div>
			<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
				Operator inventory
			</p>
			<h1 class="font-heading text-3xl font-bold">Shared loan queue</h1>
			<p class="mt-2 max-w-2xl text-sm text-muted-foreground">
				Review requests, prepare handovers, and record returned equipment. This
				queue is shared by every inventory operator.
			</p>
		</div>
		<Button
			variant="outline"
			class="min-h-11"
			disabled={queueQuery.isFetching}
			onclick={() => queueQuery.refetch()}
			><RefreshCw
				class={queueQuery.isFetching ? "animate-spin" : ""}
			/>Refresh</Button
		>
	</header>

	{#if queueQuery.isError}
		<Alert variant="destructive"
			><AlertDescription class="flex items-center justify-between gap-4"
				><span
					>{apiErrorMessage(
						queueQuery.error,
						"Could not load the loan queue",
					)}</span
				><Button variant="outline" onclick={() => queueQuery.refetch()}
					>Try again</Button
				></AlertDescription
			></Alert
		>
	{:else if queueQuery.isPending}
		<div class="grid gap-4 sm:grid-cols-2">
			<div class="h-48 animate-pulse rounded-2xl bg-muted"></div>
			<div class="h-48 animate-pulse rounded-2xl bg-muted"></div>
		</div>
	{:else if queueQuery.data}
		<div class="grid gap-6 lg:grid-cols-2">
			<section class="space-y-3 rounded-2xl border bg-background p-4 sm:p-5">
				{@render bucket(
					"Requests",
					"Approve or reject new borrowing requests.",
					queueQuery.data.pendingRequests.count,
					ClipboardList,
				)}
				{#each queueQuery.data.pendingRequests.rows as loan (loan.id)}{@render loanCard(
						loan,
						"request",
					)}{:else}<p class="py-8 text-center text-sm text-muted-foreground">
						No requests waiting.
					</p>{/each}
			</section>
			<section class="space-y-3 rounded-2xl border bg-background p-4 sm:p-5">
				{@render bucket(
					"Ready for handover",
					"Physically check the item before checkout.",
					queueQuery.data.handoversDue.count,
					PackageCheck,
				)}
				{#each queueQuery.data.handoversDue.rows as loan (loan.id)}
					<article class:opacity-65={!loan.readyForCheckout}>
						{@render loanCard(
							loan,
							"handover",
							loan.readyForCheckout,
						)}{#if !loan.readyForCheckout}<p
								class="mt-2 px-4 pb-2 text-sm font-medium text-destructive"
							>
								Checkout is currently blocked. Edit the dates before retrying.
							</p>{/if}
					</article>
				{:else}<p class="py-8 text-center text-sm text-muted-foreground">
						No handovers due.
					</p>{/each}
			</section>
			<section class="space-y-3 rounded-2xl border bg-background p-4 sm:p-5">
				{@render bucket(
					"Returns and overdue",
					"Record the item back in club custody.",
					queueQuery.data.returnsAndOverdue.count,
					ClipboardCheck,
				)}
				{#each queueQuery.data.returnsAndOverdue.rows as loan (loan.id)}{@render loanCard(
						loan,
						"return",
					)}{:else}<p class="py-8 text-center text-sm text-muted-foreground">
						No returns due.
					</p>{/each}
			</section>
			<section class="space-y-3 rounded-2xl border bg-background p-4 sm:p-5">
				{@render bucket(
					"Open maintenance",
					"Items currently out of circulation.",
					queueQuery.data.openMaintenance.count,
					Wrench,
				)}
				{#each queueQuery.data.openMaintenance.rows as item (item.id)}<article
						class="rounded-2xl border bg-card p-4"
					>
						<div class="flex items-start justify-between gap-2">
							<div>
								<h3 class="font-semibold">{item.itemLabel}</h3>
								<p class="font-mono text-xs text-muted-foreground">
									{item.itemSlug ?? "No slug"}
								</p>
							</div>
							<Badge variant="outline">Maintenance</Badge>
						</div>
						{#if item.startReason}<p class="mt-3 text-sm">
								{item.startReason}
							</p>{/if}
						<p class="mt-2 text-xs text-muted-foreground">
							Started {new Date(item.startedAt).toLocaleString()}
						</p>
					</article>{:else}<p
						class="py-8 text-center text-sm text-muted-foreground"
					>
						No maintenance work open.
					</p>{/each}
			</section>
		</div>
	{/if}

	{#if selected}
		<section
			class="fixed inset-x-0 bottom-0 z-40 max-h-[88svh] overflow-y-auto rounded-t-3xl border border-b-0 bg-background p-5 shadow-2xl sm:inset-x-auto sm:right-6 sm:bottom-6 sm:w-[28rem] sm:rounded-3xl sm:border"
			aria-label="Loan action panel"
		>
			<div class="mb-5 flex items-start justify-between gap-3">
				<div>
					<p class="text-xs font-bold tracking-wide text-primary uppercase">
						{selected.status.replace("_", " ")}
					</p>
					<h2 class="font-heading text-2xl font-bold">{selected.itemLabel}</h2>
					<p class="mt-1 text-sm text-muted-foreground">
						Borrower {shortPrincipal(selected.borrowerPrincipalId)}
					</p>
				</div>
				<Button
					variant="outline"
					size="sm"
					onclick={() => (selected = undefined)}>Close</Button
				>
			</div>
			<div
				class="mb-5 grid grid-cols-2 gap-3 rounded-xl bg-muted/50 p-3 text-sm"
			>
				<div>
					<span class="block text-xs text-muted-foreground">Start</span
					>{formatDate(selected.approvedStartOn ?? selected.requestedStartOn)}
				</div>
				<div>
					<span class="block text-xs text-muted-foreground">Due</span
					>{formatDate(selected.approvedDueOn ?? selected.requestedDueOn)}
				</div>
				{#if selected.containerPath}<div class="col-span-2">
						<span class="block text-xs text-muted-foreground">Container</span
						>{selected.containerPath}
					</div>{/if}
			</div>

			{#if selected.status === "requested"}
				<div class="space-y-4">
					<div class="grid grid-cols-2 gap-3">
						<div>
							<Label for="approve-start">Approved start</Label><Input
								id="approve-start"
								type="date"
								bind:value={startsOn}
							/>
						</div>
						<div>
							<Label for="approve-due">Approved due</Label><Input
								id="approve-due"
								type="date"
								bind:value={dueOn}
							/>
						</div>
					</div>
					<div>
						<Label for="decision-note">Decision note</Label><Textarea
							id="decision-note"
							bind:value={note}
							placeholder="Optional context for the member"
						/>
					</div>
					<div class="grid grid-cols-2 gap-2">
						<Button
							variant="destructive"
							class="min-h-12"
							disabled={pending(approve, reject)}
							onclick={() =>
								reject.mutate({
									path: { loanId: selected!.id },
									body: { note: note.trim() || undefined },
								})}>Reject</Button
						><Button
							class="min-h-12"
							disabled={!startsOn || !dueOn || pending(approve, reject)}
							onclick={() =>
								approve.mutate({
									path: { loanId: selected!.id },
									body: { startsOn, dueOn, note: note.trim() || undefined },
								})}>Approve</Button
						>
					</div>
				</div>
			{:else if selected.status === "approved"}
				<div class="space-y-4">
					<div class="grid grid-cols-2 gap-3">
						<div>
							<Label for="edit-start">Start</Label><Input
								id="edit-start"
								type="date"
								bind:value={startsOn}
							/>
						</div>
						<div>
							<Label for="edit-due">Due</Label><Input
								id="edit-due"
								type="date"
								bind:value={dueOn}
							/>
						</div>
					</div>
					<Button
						variant="outline"
						class="w-full min-h-11"
						disabled={editDates.isPending}
						onclick={() =>
							editDates.mutate({
								path: { loanId: selected!.id },
								body: { startsOn, dueOn },
							})}><CalendarClock />Save dates</Button
					>
					<div>
						<Label for="cancel-note">Cancellation note</Label><Textarea
							id="cancel-note"
							bind:value={note}
						/>
					</div>
					<div class="grid grid-cols-2 gap-2">
						<Button
							variant="destructive"
							class="min-h-12"
							disabled={pending(cancel, checkout)}
							onclick={() =>
								cancel.mutate({
									path: { loanId: selected!.id },
									body: { note: note.trim() || undefined },
								})}>Cancel loan</Button
						><Button
							class="min-h-12"
							disabled={pending(cancel, checkout) || !selectedReadyForCheckout}
							onclick={() =>
								checkout.mutate({ path: { loanId: selected!.id } })}
							>Record checkout</Button
						>
					</div>
				</div>
			{:else if selected.status === "checked_out"}
				<div class="space-y-4">
					<div>
						<Label for="return-due">Due date</Label><Input
							id="return-due"
							type="date"
							bind:value={dueOn}
						/>
					</div>
					<Button
						variant="outline"
						class="w-full min-h-11"
						disabled={editDates.isPending}
						onclick={() =>
							editDates.mutate({
								path: { loanId: selected!.id },
								body: { dueOn },
							})}><CalendarClock />Update due date</Button
					><Button
						class="w-full min-h-12"
						disabled={returnLoan.isPending}
						onclick={() =>
							returnLoan.mutate({ path: { loanId: selected!.id } })}
						>Record return</Button
					>
				</div>
			{/if}
		</section>
	{/if}
</div>
