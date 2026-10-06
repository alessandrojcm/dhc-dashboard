<script lang="ts">
import { type InventoryOperatorLoan } from "@dhc/api-client";
import { Alert, AlertDescription } from "#lib/components/ui/alert/index.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import {
	NativeSelect,
	NativeSelectOption,
} from "#lib/components/ui/native-select/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import DatePicker from "#lib/components/ui/date-picker.svelte";
import { Label } from "#lib/components/ui/label/index.js";
import * as Sheet from "#lib/components/ui/sheet/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import {
	dndState,
	draggable,
	droppable,
	type DragDropState,
} from "@thisux/sveltednd";
import InventoryPageHeader from "#lib/components/inventory/InventoryPageHeader.svelte";
import { apiErrorMessage } from "#lib/api-error.js";
import {
	ArrowRight,
	CalendarClock,
	ClipboardCheck,
	ClipboardList,
	Clock3,
	GripVertical,
	PackageCheck,
	RefreshCw,
	TriangleAlert,
	UserRound,
	Wrench,
} from "@lucide/svelte";
import { parseDate } from "@internationalized/date";
import { MediaQuery } from "svelte/reactivity";
import {
	createLoanQueueBoard,
	type LoanCardKind,
	type LoanDragData,
} from "./loan-queue-board.svelte.js";

// Drag only makes sense on the wide four-column board. Mobile shows one
// queue at a time through the selector, so there is no other column to drop
// onto. `isDesktop` tracks the `lg` breakpoint the board uses.
// `MediaQuery` reports false during SSR, matching the mobile-first markup.
const desktop = new MediaQuery("min-width: 1024px", false);

// A drop never writes: an allowed drop opens the action sheet below, whose
// command stays the single write path. Phoenix re-decides under the item
// lock, so a stale advisory `readyForCheckout` is safe.
const board = createLoanQueueBoard({
	isDesktop: () => desktop.current,
	hover: () =>
		dndState.isDragging
			? {
					targetContainer: dndState.targetContainer,
					// SAFETY: every draggable on this board sets dragData to
					// LoanDragData; the controller ignores anything without a loan.
					dragged: dndState.draggedItem as LoanDragData | undefined,
				}
			: undefined,
});
const queueQuery = board.queue;

let selectedTrigger = $state<HTMLElement | null>(null);

function handleLoanDrop(state: DragDropState<LoanDragData>) {
	if (!state.draggedItem || !state.targetContainer) return;
	selectedTrigger = null;
	board.drop(state.targetContainer, state.draggedItem);
}

function formatDate(value: string | null) {
	return value?.slice(0, 10) ?? "—";
}

function dateValue(value: string) {
	return value ? parseDate(value) : undefined;
}

function shortPrincipal(id: string) {
	return id.slice(0, 8);
}
</script>

{#snippet loanCard(
	loan: InventoryOperatorLoan,
	kind: LoanCardKind,
	readyForCheckout = false,
)}
	<article
		class="inventory-card p-4"
		use:draggable={{
			container:
				kind === "request"
					? "requests"
					: kind === "handover"
						? "handovers"
						: "returns",
			dragData: { loan, readyForCheckout } satisfies LoanDragData,
			handle: ".loan-drag-handle",
			keyboard: true,
			disabled: !board.canDrag(loan, kind),
		}}
		use:droppable={{
			container: `card:${loan.id}`,
			callbacks: { onDrop: handleLoanDrop },
		}}
	>
		<div class="flex items-start justify-between gap-3">
			<div class="min-w-0">
				<div class="flex items-start gap-3">
					{#if board.canDrag(loan, kind)}<span
							class="loan-drag-handle mt-1 hidden shrink-0 cursor-grab text-muted-foreground lg:inline-flex"
							role="button"
							aria-label="Drag to move {loan.itemLabel}"
						>
							<GripVertical class="size-5" aria-hidden="true" />
						</span>{/if}
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
					board.open(loan, readyForCheckout);
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
			<NativeSelect
				id="mobile-loan-queue-view"
				class="w-full [&_select]:h-11 [&_select]:px-3 [&_select]:pr-9 [&_select]:font-semibold"
				value={board.activeView}
				onchange={(event) => board.changeView(event.currentTarget.value)}
			>
				{#each board.views as option (option.value)}
					<NativeSelectOption value={option.value}
						>{option.label} — {option.count}</NativeSelectOption
					>
				{/each}
			</NativeSelect>
		</div>
		<p class="hidden text-sm text-muted-foreground lg:block">
			On wide screens you can drag a card by its grip handle to another column:
			a request to Ready for handover approves it, an approved loan to Returns
			checks it out. Every drop opens the action panel to confirm; nothing moves
			until you confirm. Returns and overdue loans have no handle because they
			cannot move to another column.
		</p>
		<div
			class="grid items-start gap-4 lg:grid-cols-[repeat(4,minmax(20rem,1fr))] lg:overflow-x-auto lg:pb-2"
			data-testid="loan-queue-board"
		>
			{#if board.notice}
				<p
					class="rounded-xl border border-destructive/40 bg-destructive/5 px-4 py-3 text-sm font-medium text-destructive lg:col-span-4"
					role="status"
				>
					{board.notice}
				</p>
			{/if}
			<section
				class="inventory-panel space-y-3 p-4 sm:p-5 lg:block"
				class:hidden={board.activeView !== "requests"}
				class:drag-invalid={board.isInvalidHover("requests")}
				use:droppable={{
					container: "requests",
					callbacks: { onDrop: handleLoanDrop },
				}}
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
				class:hidden={board.activeView !== "handovers"}
				class:drag-invalid={board.isInvalidHover("handovers")}
				use:droppable={{
					container: "handovers",
					callbacks: { onDrop: handleLoanDrop },
				}}
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
				class:hidden={board.activeView !== "returns"}
				class:drag-invalid={board.isInvalidHover("returns")}
				use:droppable={{
					container: "returns",
					callbacks: { onDrop: handleLoanDrop },
				}}
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
				class:hidden={board.activeView !== "maintenance"}
				class:drag-invalid={board.isInvalidHover("maintenance")}
				data-testid="open-maintenance-bucket"
				use:droppable={{
					container: "maintenance",
					callbacks: { onDrop: handleLoanDrop },
				}}
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
		open={Boolean(board.selection)}
		onOpenChange={(open) => {
			if (!open) board.close();
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
			{#if board.selection}
				{@const selection = board.selection}
				{@const selected = selection.loan}
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
					{#if board.error}
						<Alert variant="destructive">
							<AlertDescription>{board.error}</AlertDescription>
						</Alert>
					{/if}
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
										value={dateValue(selection.startsOn)}
										onValueChange={(value) => {
											if (value) board.setStartsOn(value.toString());
										}}
									/>
								</div>
								<div class="min-w-0 space-y-1">
									<Label for="approve-due">Approved due</Label><DatePicker
										id="approve-due"
										label="Approved due"
										value={dateValue(selection.dueOn)}
										minValue={dateValue(selection.startsOn)}
										onValueChange={(value) => {
											if (value) board.setDueOn(value.toString());
										}}
									/>
								</div>
							</div>
							<div>
								<Label for="decision-note">Decision note</Label><Textarea
									id="decision-note"
									bind:value={selection.note}
									placeholder="Optional context for the member"
								/>
							</div>
							<div class="grid grid-cols-2 gap-2">
								<Button
									variant="destructive"
									class="min-h-12"
									disabled={board.busy}
									onclick={board.reject}
									>{board.pending.reject ? "Rejecting…" : "Reject"}</Button
								><Button
									class="min-h-12"
									disabled={!selection.startsOn ||
										!selection.dueOn ||
										board.busy}
									onclick={board.approve}
									>{board.pending.approve ? "Approving…" : "Approve"}</Button
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
										value={dateValue(selection.startsOn)}
										onValueChange={(value) => {
											if (value) board.setStartsOn(value.toString());
										}}
									/>
								</div>
								<div class="min-w-0 space-y-1">
									<Label for="edit-due">Due</Label><DatePicker
										id="edit-due"
										label="Due"
										value={dateValue(selection.dueOn)}
										minValue={dateValue(selection.startsOn)}
										onValueChange={(value) => {
											if (value) board.setDueOn(value.toString());
										}}
									/>
								</div>
							</div>
							<Button
								variant="outline"
								class="w-full min-h-11"
								disabled={board.busy}
								onclick={board.editDates}
								><CalendarClock />{board.pending.editDates
									? "Saving…"
									: "Save dates"}</Button
							>
							<div>
								<Label for="cancel-note">Cancellation note</Label><Textarea
									id="cancel-note"
									bind:value={selection.note}
								/>
							</div>
							<div class="grid grid-cols-2 gap-2">
								<Button
									variant="destructive"
									class="min-h-12"
									disabled={board.busy}
									onclick={board.cancel}
									>{board.pending.cancel
										? "Cancelling…"
										: "Cancel loan"}</Button
								><Button
									class="min-h-12"
									disabled={board.busy || !selection.readyForCheckout}
									onclick={board.checkout}
									>{board.pending.checkout
										? "Recording…"
										: "Record checkout"}</Button
								>
							</div>
						</div>
					{:else if selected.status === "checked_out"}
						<div class="space-y-4">
							<div class="min-w-0 space-y-1">
								<Label for="return-due">Due date</Label><DatePicker
									id="return-due"
									label="Due date"
									value={dateValue(selection.dueOn)}
									onValueChange={(value) => {
										if (value) board.setDueOn(value.toString());
									}}
								/>
							</div>
							<Button
								variant="outline"
								class="w-full min-h-11"
								disabled={board.busy}
								onclick={board.editDates}
								><CalendarClock />{board.pending.editDates
									? "Updating…"
									: "Update due date"}</Button
							><Button
								class="w-full min-h-12"
								disabled={board.busy}
								onclick={board.returnLoan}
								>{board.pending.returnLoan
									? "Recording…"
									: "Record return"}</Button
							>
						</div>
					{/if}
				</div>
			{/if}
		</Sheet.Content>
	</Sheet.Root>
</div>

<style>
/* Drag affordances shared with the sveltednd prototype (variant C). */
:global(.dragging) {
	opacity: 0.55;
}
:global(.drag-over) {
	outline: 2px dashed var(--color-primary, #1f4f85);
	outline-offset: 2px;
}
/* Refused hover column: the drop machine would not act on this move. */
:global(.drag-invalid) {
	outline: 2px solid var(--color-destructive, #c0392b);
	outline-offset: 2px;
}
</style>
