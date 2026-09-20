<script lang="ts">
import { goto } from "$app/navigation";
import { page } from "$app/state";
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
import DatePicker from "$lib/components/ui/date-picker.svelte";
import { Label } from "$lib/components/ui/label";
import * as Sheet from "$lib/components/ui/sheet";
import { Textarea } from "$lib/components/ui/textarea";
import InventoryPageHeader from "$lib/components/inventory/InventoryPageHeader.svelte";
import { apiErrorMessage } from "$lib/api-error";
import {
	ArrowRight,
	CalendarClock,
	ChevronDown,
	ClipboardCheck,
	ClipboardList,
	Clock3,
	PackageCheck,
	RefreshCw,
	TriangleAlert,
	UserRound,
	Wrench,
} from "@lucide/svelte";
import { toast } from "svelte-sonner";
import { parseDate } from "@internationalized/date";

let selected = $state<InventoryOperatorLoan | undefined>();
let selectedTrigger = $state<HTMLElement | null>(null);
let selectedReadyForCheckout = $state(false);
let startsOn = $state("");
let dueOn = $state("");
let note = $state("");

type QueueView = "requests" | "handovers" | "returns" | "maintenance";

const queueQuery = createQuery(() => ({
	...inventoryOperatorLoanQueueShowOptions(),
	select: (response) => response.data,
}));

const queueOptions = $derived([
	{
		value: "requests" as const,
		label: "Requests",
		count: queueQuery.data?.pendingRequests.count ?? 0,
	},
	{
		value: "handovers" as const,
		label: "Ready for handover",
		count: queueQuery.data?.handoversDue.count ?? 0,
	},
	{
		value: "returns" as const,
		label: "Returns and overdue",
		count: queueQuery.data?.returnsAndOverdue.count ?? 0,
	},
	{
		value: "maintenance" as const,
		label: "Open maintenance",
		count: queueQuery.data?.openMaintenance.count ?? 0,
	},
]);
const defaultQueue = $derived<QueueView>(
	queueQuery.data?.pendingRequests.count
		? "requests"
		: queueQuery.data?.returnsAndOverdue.count
			? "returns"
			: queueQuery.data?.handoversDue.count
				? "handovers"
				: queueQuery.data?.openMaintenance.count
					? "maintenance"
					: "requests",
);
const requestedQueue = $derived(
	parseQueueView(page.url.searchParams.get("view")),
);
const activeQueue = $derived(requestedQueue ?? defaultQueue);
const activeQueueOption = $derived(
	queueOptions.find((option) => option.value === activeQueue) ??
		queueOptions[0],
);

function parseQueueView(value: string | null): QueueView | undefined {
	return value === "requests" ||
		value === "handovers" ||
		value === "returns" ||
		value === "maintenance"
		? value
		: undefined;
}

function changeQueue(value: string) {
	const view = parseQueueView(value);
	if (!view || view === activeQueue) return;
	const url = new URL(page.url);
	url.searchParams.set("view", view);
	void goto(url, { keepFocus: true, noScroll: true });
}

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

function dateValue(value: string) {
	return value ? parseDate(value) : undefined;
}

function shortPrincipal(id: string) {
	return id.slice(0, 8);
}

const busy = $derived(
	approve.isPending ||
		reject.isPending ||
		cancel.isPending ||
		checkout.isPending ||
		returnLoan.isPending ||
		editDates.isPending,
);
</script>

{#snippet loanCard(
	loan: InventoryOperatorLoan,
	kind: "request" | "handover" | "return",
	readyForCheckout = false,
)}
	<article class="inventory-card p-4">
		<div class="flex items-start justify-between gap-3">
			<div class="min-w-0">
				<div class="flex items-start gap-3">
					<div
						class="grid size-10 shrink-0 place-items-center rounded-xl bg-primary/10 text-primary"
					>
						{#if kind === "request"}<ClipboardList
								class="size-5"
								aria-hidden="true"
							/>
						{:else if kind === "handover"}<PackageCheck
								class="size-5"
								aria-hidden="true"
							/>
						{:else}<ClipboardCheck class="size-5" aria-hidden="true" />{/if}
					</div>
					<div class="min-w-0">
						<h3 class="font-semibold leading-snug">{loan.itemLabel}</h3>
						<Badge variant="outline" class="mt-1 font-mono text-[0.7rem]"
							>{loan.itemSlug}</Badge
						>
					</div>
				</div>
				<div class="mt-3 grid gap-1.5 text-sm text-muted-foreground">
					<p class="flex items-center gap-2">
						<UserRound class="size-4 shrink-0" aria-hidden="true" />
						Member {shortPrincipal(loan.borrowerPrincipalId)}
					</p>
					<p class="flex items-center gap-2">
						<Clock3 class="size-4 shrink-0" aria-hidden="true" />
						{formatDate(loan.approvedStartOn ?? loan.requestedStartOn)}
						<ArrowRight class="size-3.5" aria-hidden="true" />
						{formatDate(loan.approvedDueOn ?? loan.requestedDueOn)}
					</p>
				</div>
				{#if loan.containerPath}<p
						class="mt-3 rounded-xl bg-primary/5 px-3 py-2 text-sm"
					>
						<span class="font-medium">Collect from:</span>
						{loan.containerPath}
					</p>{/if}
				{#if loan.requestNote}<p
						class="mt-2 border-l-2 border-secondary bg-muted/50 px-3 py-2 text-sm"
					>
						{loan.requestNote}
					</p>{/if}
			</div>
			{#if loan.overdue}<Badge variant="destructive" class="shrink-0 gap-1"
					><TriangleAlert class="size-3" />Overdue</Badge
				>{/if}
		</div>
		<div class="mt-4">
			<Button
				class="min-h-11 w-full justify-between"
				onclick={(event) => {
					selectedTrigger = event.currentTarget;
					choose(loan, readyForCheckout);
				}}
			>
				{kind === "request"
					? "Review request"
					: kind === "handover"
						? "Record handover"
						: "Record return"}<ArrowRight class="size-4" aria-hidden="true" />
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
	<div class="flex items-center gap-3 border-b border-border/70 pb-4">
		<div
			class="grid size-11 shrink-0 place-items-center rounded-xl bg-primary/10 text-primary"
		>
			<Icon class="size-5" />
		</div>
		<div class="min-w-0 flex-1">
			<h2 class="font-heading text-xl font-bold">{title}</h2>
			<p class="text-sm text-muted-foreground">{description}</p>
		</div>
		<Badge
			variant={count ? "secondary" : "outline"}
			class="min-w-8 justify-center text-sm">{count}</Badge
		>
	</div>
{/snippet}

<svelte:head><title>Loan queue | Dublin HEMA Club</title></svelte:head>

<div class="inventory-page max-w-none">
	{#snippet refreshAction()}
		<Button
			variant="outline"
			class="size-11 px-0 sm:w-auto sm:px-5"
			aria-label="Refresh loan queue"
			title="Refresh"
			disabled={queueQuery.isFetching}
			onclick={() => queueQuery.refetch()}
			><RefreshCw class={queueQuery.isFetching ? "animate-spin" : ""} /><span
				class="sr-only sm:not-sr-only">Refresh</span
			></Button
		>
	{/snippet}
	<InventoryPageHeader
		eyebrow="Quartermaster"
		title="Shared loan queue"
		icon={ClipboardList}
		actions={refreshAction}
		class="flex-row items-end justify-between"
	/>

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
		<div
			class="sticky top-[2.8125rem] z-10 -mx-4 border-y border-border/70 bg-background/95 px-4 py-3 shadow-sm backdrop-blur-md sm:-mx-6 sm:px-6 lg:hidden"
			data-testid="mobile-loan-queue-selector"
		>
			<Label for="mobile-loan-queue-view" class="mb-2 text-xs font-semibold">
				Queue view
			</Label>
			<div class="relative">
				<select
					id="mobile-loan-queue-view"
					class="focus-visible:border-ring focus-visible:ring-ring/50 h-11 w-full appearance-none rounded-md border border-input bg-background px-3 pr-20 text-sm font-semibold shadow-xs outline-none focus-visible:ring-[3px]"
					value={activeQueue}
					onchange={(event) => changeQueue(event.currentTarget.value)}
				>
					{#each queueOptions as option (option.value)}
						<option value={option.value}>{option.label} — {option.count}</option
						>
					{/each}
				</select>
				<span
					class="pointer-events-none absolute inset-y-0 right-3 flex items-center gap-2"
					aria-hidden="true"
				>
					<Badge
						variant={activeQueueOption.count ? "secondary" : "outline"}
						class="min-w-7 justify-center"
					>
						{activeQueueOption.count}
					</Badge>
					<ChevronDown class="size-4 text-muted-foreground" />
				</span>
			</div>
		</div>
		<div
			class="grid items-start gap-4 lg:grid-cols-[repeat(4,minmax(20rem,1fr))] lg:overflow-x-auto lg:pb-2"
			data-testid="loan-queue-board"
		>
			<section
				class="inventory-panel space-y-3 p-4 sm:p-5 lg:block"
				class:hidden={activeQueue !== "requests"}
			>
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
			<section
				class="inventory-panel space-y-3 p-4 sm:p-5 lg:block"
				class:hidden={activeQueue !== "handovers"}
			>
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
			<section
				class="inventory-panel space-y-3 p-4 sm:p-5 lg:block"
				class:hidden={activeQueue !== "returns"}
			>
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
			<section
				class="inventory-panel space-y-3 p-4 sm:p-5 lg:block"
				class:hidden={activeQueue !== "maintenance"}
				data-testid="open-maintenance-bucket"
			>
				{@render bucket(
					"Open maintenance",
					"Items out of circulation until a quartermaster ends maintenance.",
					queueQuery.data.openMaintenance.count,
					Wrench,
				)}
				{#each queueQuery.data.openMaintenance.rows as row (row.id)}
					<article class="inventory-card p-4">
						<div class="flex items-start gap-3">
							<div
								class="grid size-10 shrink-0 place-items-center rounded-xl bg-primary/10 text-primary"
							>
								<Wrench class="size-5" aria-hidden="true" />
							</div>
							<div class="min-w-0">
								<h3 class="font-semibold leading-snug">{row.itemLabel}</h3>
								<Badge variant="outline" class="mt-1 font-mono text-[0.7rem]"
									>{row.itemSlug}</Badge
								>
								<p class="mt-2 text-sm text-muted-foreground">
									{row.startReason ?? "Open maintenance"}
								</p>
							</div>
						</div>
						<div class="mt-4">
							<Button
								class="min-h-11 w-full justify-between"
								href={row.itemSlug
									? `/dashboard/inventory/items?slug=${encodeURIComponent(row.itemSlug)}`
									: "/dashboard/inventory/items"}
							>
								Open item<ArrowRight class="size-4" aria-hidden="true" />
							</Button>
						</div>
					</article>
				{:else}
					<p class="py-8 text-center text-sm text-muted-foreground">
						No items in maintenance.
					</p>
				{/each}
			</section>
		</div>
	{/if}

	<Sheet.Root
		open={Boolean(selected)}
		onOpenChange={(open) => {
			if (!open) selected = undefined;
		}}
		onOpenChangeComplete={(open) => {
			if (!open) selectedTrigger?.focus();
		}}
	>
		<Sheet.Content
			side="bottom-right"
			data-testid="loan-action-panel"
			aria-label="Loan action panel"
			class="max-h-[92svh] w-full max-w-none gap-0 overflow-hidden rounded-t-2xl p-0 sm:max-h-none sm:w-[28rem] sm:max-w-[calc(100vw-2rem)] sm:rounded-none"
		>
			{#if selected}
				<Sheet.Header
					class="shrink-0 border-b bg-primary/7 px-5 pt-[max(1.25rem,env(safe-area-inset-top))] pr-16 pb-5 text-left sm:px-6 sm:pt-6"
				>
					<p class="text-xs font-bold tracking-wide text-primary uppercase">
						{selected.status.replace("_", " ")}
					</p>
					<Sheet.Title class="font-heading text-2xl font-bold">
						{selected.itemLabel}
					</Sheet.Title>
					<Sheet.Description class="mt-1 text-sm text-muted-foreground">
						Borrower {shortPrincipal(selected.borrowerPrincipalId)}
					</Sheet.Description>
				</Sheet.Header>
				<div
					class="min-h-0 flex-1 space-y-5 overflow-y-auto overscroll-contain p-5 sm:p-6"
				>
					<div
						class="mb-5 grid grid-cols-2 gap-3 rounded-xl bg-muted/50 p-3 text-sm"
					>
						<div>
							<span class="block text-xs text-muted-foreground">Start</span
							>{formatDate(
								selected.approvedStartOn ?? selected.requestedStartOn,
							)}
						</div>
						<div>
							<span class="block text-xs text-muted-foreground">Due</span
							>{formatDate(selected.approvedDueOn ?? selected.requestedDueOn)}
						</div>
						{#if selected.containerPath}<div class="col-span-2">
								<span class="block text-xs text-muted-foreground"
									>Container</span
								>{selected.containerPath}
							</div>{/if}
					</div>

					{#if selected.status === "requested"}
						<div class="space-y-4">
							<div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
								<div class="min-w-0 space-y-1">
									<Label for="approve-start">Approved start</Label><DatePicker
										id="approve-start"
										label="Approved start"
										value={dateValue(startsOn)}
										onValueChange={(value) => {
											if (value) {
												startsOn = value.toString();
												if (dueOn < startsOn) dueOn = startsOn;
											}
										}}
									/>
								</div>
								<div class="min-w-0 space-y-1">
									<Label for="approve-due">Approved due</Label><DatePicker
										id="approve-due"
										label="Approved due"
										value={dateValue(dueOn)}
										minValue={dateValue(startsOn)}
										onValueChange={(value) => {
											if (value) dueOn = value.toString();
										}}
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
									disabled={busy}
									onclick={() =>
										reject.mutate({
											path: { loanId: selected!.id },
											body: { note: note.trim() || undefined },
										})}>Reject</Button
								><Button
									class="min-h-12"
									disabled={!startsOn || !dueOn || busy}
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
							<div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
								<div class="min-w-0 space-y-1">
									<Label for="edit-start">Start</Label><DatePicker
										id="edit-start"
										label="Start"
										value={dateValue(startsOn)}
										onValueChange={(value) => {
											if (value) {
												startsOn = value.toString();
												if (dueOn < startsOn) dueOn = startsOn;
											}
										}}
									/>
								</div>
								<div class="min-w-0 space-y-1">
									<Label for="edit-due">Due</Label><DatePicker
										id="edit-due"
										label="Due"
										value={dateValue(dueOn)}
										minValue={dateValue(startsOn)}
										onValueChange={(value) => {
											if (value) dueOn = value.toString();
										}}
									/>
								</div>
							</div>
							<Button
								variant="outline"
								class="w-full min-h-11"
								disabled={busy}
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
									disabled={busy}
									onclick={() =>
										cancel.mutate({
											path: { loanId: selected!.id },
											body: { note: note.trim() || undefined },
										})}>Cancel loan</Button
								><Button
									class="min-h-12"
									disabled={busy || !selectedReadyForCheckout}
									onclick={() =>
										checkout.mutate({ path: { loanId: selected!.id } })}
									>Record checkout</Button
								>
							</div>
						</div>
					{:else if selected.status === "checked_out"}
						<div class="space-y-4">
							<div class="min-w-0 space-y-1">
								<Label for="return-due">Due date</Label><DatePicker
									id="return-due"
									label="Due date"
									value={dateValue(dueOn)}
									onValueChange={(value) => {
										if (value) dueOn = value.toString();
									}}
								/>
							</div>
							<Button
								variant="outline"
								class="w-full min-h-11"
								disabled={busy}
								onclick={() =>
									editDates.mutate({
										path: { loanId: selected!.id },
										body: { dueOn },
									})}><CalendarClock />Update due date</Button
							><Button
								class="w-full min-h-12"
								disabled={busy}
								onclick={() =>
									returnLoan.mutate({ path: { loanId: selected!.id } })}
								>Record return</Button
							>
						</div>
					{/if}
				</div>
			{/if}
		</Sheet.Content>
	</Sheet.Root>
</div>
