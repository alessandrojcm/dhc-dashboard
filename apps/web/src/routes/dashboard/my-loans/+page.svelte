<script lang="ts">
import { createQuery, keepPreviousData } from "@tanstack/svelte-query";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Skeleton } from "$lib/components/ui/skeleton";
import * as Sheet from "$lib/components/ui/sheet";
import * as Tabs from "$lib/components/ui/tabs";
import InventoryPageHeader from "$lib/components/inventory/InventoryPageHeader.svelte";
import MemberLoanDetail from "$lib/components/inventory/MemberLoanDetail.svelte";
import {
	ArrowRight,
	CalendarCheck2,
	ClipboardList,
	History,
	RefreshCw,
	TriangleAlert,
} from "@lucide/svelte";
import {
	inventoryMemberLoansListOptions,
	type InventoryMemberLoan,
} from "@dhc/api-client";

// ALE-288 own-loan history (ALE-280 story 60): the member's obligations live
// here, separate from browsing — cancel before checkout and review past
// outcomes in one place. Every row renders the retained snapshot, never a
// live item read, so history survives archival.

type StatusFilter = "all" | "open" | "closed";

let status = $state<StatusFilter>("all");
let cursor = $state<string | undefined>(undefined);
let selectedLoanId = $state<string | undefined>();
let selectedLoanTrigger = $state<HTMLElement | null>(null);

const loansQuery = createQuery(() => ({
	...inventoryMemberLoansListOptions({
		query: { limit: 25, status, cursor },
	}),
	placeholderData: keepPreviousData,
	select: (response) => response.data,
}));

const loans = $derived(loansQuery.data?.loans ?? []);

function onStatusChange(value: StatusFilter) {
	status = value;
	cursor = undefined;
}

function statusLabel(loan: InventoryMemberLoan): string {
	return loan.status.replace("_", " ");
}

function statusVariant(
	loan: InventoryMemberLoan,
): "secondary" | "outline" | "destructive" {
	switch (loan.status) {
		case "requested":
		case "approved":
			return "secondary";
		case "checked_out":
			return "secondary";
		case "rejected":
		case "cancelled":
			return "outline";
		case "returned":
			return "outline";
		default:
			return "outline";
	}
}

function formatDate(iso: string | null): string {
	if (!iso) return "—";
	return iso.slice(0, 10);
}
</script>

<svelte:head>
	<title>My loans | Dublin HEMA Club</title>
</svelte:head>

<div class="inventory-page max-w-5xl">
	<InventoryPageHeader
		eyebrow="Member inventory"
		title="My loans"
		description="Keep track of requests, collection dates, and returned equipment. You can cancel any time before checkout."
		icon={ClipboardList}
	/>

	<Tabs.Root
		value={status}
		onValueChange={(v) => v && onStatusChange(v as StatusFilter)}
		class="gap-5"
	>
		<Tabs.List
			class="grid h-auto w-full grid-cols-3 p-1"
			aria-label="Loan history views"
		>
			<Tabs.Trigger value="all" class="min-h-11 gap-1.5 px-2">
				<ClipboardList aria-hidden="true" class="size-4" />
				All
			</Tabs.Trigger>
			<Tabs.Trigger value="open" class="min-h-11 gap-1.5 px-2">
				<CalendarCheck2 aria-hidden="true" class="size-4" />
				Current
			</Tabs.Trigger>
			<Tabs.Trigger value="closed" class="min-h-11 gap-1.5 px-2">
				<History aria-hidden="true" class="size-4" />
				Past
			</Tabs.Trigger>
		</Tabs.List>

		<Tabs.Content value={status}>
			{#if loansQuery.isPending}
				<div class="space-y-3" aria-label="Loading loans">
					{#each { length: 3 } as _, index (index)}
						<div class="rounded-2xl border border-border bg-card p-4">
							<Skeleton class="h-5 w-2/3" />
							<Skeleton class="mt-2 h-4 w-1/2" />
						</div>
					{/each}
				</div>
			{:else if loansQuery.isError}
				<Alert variant="destructive">
					<AlertDescription
						class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"
					>
						<span>
							{loansQuery.error.errors?.detail ??
								"We couldn't load your loans."}
						</span>
						<Button
							variant="outline"
							size="sm"
							class="min-h-10"
							onclick={() => loansQuery.refetch()}
						>
							<RefreshCw aria-hidden="true" />
							Try again
						</Button>
					</AlertDescription>
				</Alert>
			{:else if loans.length === 0}
				<div
					class="flex flex-col items-center rounded-2xl border border-border bg-card px-6 py-12 text-center"
				>
					<ClipboardList
						class="mb-4 size-12 text-muted-foreground"
						aria-hidden="true"
					/>
					<h2 class="text-lg font-semibold">
						{status === "all"
							? "No loans yet"
							: status === "open"
								? "Nothing on loan"
								: "No past loans"}
					</h2>
					<p class="mt-1 text-sm text-muted-foreground">
						{status === "all"
							? "Browse the equipment catalog and send your first request."
							: status === "open"
								? "Requests you send will show up here until they're done."
								: "Returned, rejected, and cancelled requests land here."}
					</p>
					{#if status === "all"}
						<Button href="/dashboard/equipment" class="mt-4 min-h-11">
							Browse equipment
						</Button>
					{/if}
				</div>
			{:else}
				<p class="mb-2 text-sm text-muted-foreground" aria-live="polite">
					{loansQuery.data?.totalCount} loan{loansQuery.data?.totalCount === 1
						? ""
						: "s"}{loansQuery.isFetching ? " · updating…" : ""}
				</p>
				<div class="grid gap-3 md:grid-cols-2">
					{#each loans as loan (loan.id)}
						<a
							href="/dashboard/my-loans"
							class="inventory-card group block p-4 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
							onclick={(event) => {
								event.preventDefault();
								selectedLoanTrigger = event.currentTarget;
								selectedLoanId = loan.id;
							}}
						>
							<div class="flex items-start justify-between gap-2">
								<div class="min-w-0">
									<p
										class="text-xs font-bold tracking-wide text-primary uppercase"
									>
										{statusLabel(loan)}
									</p>
									<h2 class="mt-1 font-semibold">{loan.itemLabel}</h2>
									<p class="mt-1 text-sm text-muted-foreground">
										{formatDate(loan.approvedStartOn ?? loan.requestedStartOn)}
										→ {formatDate(loan.approvedDueOn ?? loan.requestedDueOn)}
									</p>
								</div>
								<div class="flex shrink-0 flex-col items-end gap-1.5">
									<Badge variant={statusVariant(loan)}>
										{statusLabel(loan)}
									</Badge>
									{#if loan.overdue}
										<Badge variant="destructive" class="gap-1">
											<TriangleAlert class="size-3" aria-hidden="true" />
											Overdue
										</Badge>
									{/if}
								</div>
							</div>
							<div
								class="mt-3 flex justify-end border-t pt-3 text-sm font-semibold text-primary"
							>
								<span class="flex items-center gap-1"
									>View details <ArrowRight
										class="size-4 transition-transform group-hover:translate-x-0.5"
										aria-hidden="true"
									/></span
								>
							</div>
						</a>
					{/each}
				</div>

				{#if cursor || loansQuery.data?.nextCursor}
					<div class="mt-4 flex items-center justify-between gap-2">
						{#if loansQuery.data?.previousCursor}
							<Button
								variant="outline"
								size="sm"
								class="min-h-11"
								onclick={() => {
									cursor = loansQuery.data?.previousCursor ?? undefined;
								}}
							>
								Previous
							</Button>
						{:else}
							<span></span>
						{/if}
						{#if loansQuery.data?.nextCursor}
							<Button
								variant="outline"
								size="sm"
								class="min-h-11"
								onclick={() => {
									cursor = loansQuery.data?.nextCursor ?? undefined;
								}}
							>
								Next
							</Button>
						{/if}
					</div>
				{/if}
			{/if}
		</Tabs.Content>
	</Tabs.Root>
</div>

{#if selectedLoanId}
	<Sheet.Root
		open
		onOpenChange={(open) => {
			if (!open) selectedLoanId = undefined;
		}}
		onOpenChangeComplete={(open) => {
			if (!open) selectedLoanTrigger?.focus();
		}}
	>
		<Sheet.Content
			side="bottom"
			class="max-h-[92svh] w-full max-w-none gap-0 overflow-hidden rounded-t-2xl p-0 sm:inset-y-0 sm:right-0 sm:left-auto sm:h-full sm:max-h-none sm:w-[40rem] sm:max-w-[calc(100vw-2rem)] sm:rounded-none sm:border-t-0 sm:border-l sm:data-[state=closed]:slide-out-to-right sm:data-[state=open]:slide-in-from-right"
		>
			<Sheet.Header class="sr-only">
				<Sheet.Title>Loan details</Sheet.Title>
				<Sheet.Description>
					Review this loan and its collection or return status.
				</Sheet.Description>
			</Sheet.Header>
			<div
				class="min-h-0 min-w-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-contain px-5 pt-[max(1.5rem,env(safe-area-inset-top))] pb-[max(1.5rem,env(safe-area-inset-bottom))] sm:px-6 sm:py-6"
			>
				{#key selectedLoanId}
					<MemberLoanDetail loanId={selectedLoanId} />
				{/key}
			</div>
		</Sheet.Content>
	</Sheet.Root>
{/if}
