<!-- PROTOTYPE — throwaway. VariantC — Cross-container kanban -->
<script lang="ts">
import { Badge } from "$lib/components/ui/badge/index.js";
import * as Card from "$lib/components/ui/card/index.js";
import {
	attachDraggable,
	attachDroppable,
	droppable,
	type DragDropState,
} from "@thisux/sveltednd";

const COLUMN_IDS = ["requested", "ready", "out", "overdue"] as const;
type ColumnId = (typeof COLUMN_IDS)[number];

const COLUMN_LABELS = {
	requested: "Requested",
	ready: "Ready for handover",
	out: "Out",
	overdue: "Overdue",
} as const;

type LoanCard = {
	id: string;
	member: string;
	itemName: string;
	code: string;
	notes: string;
	column: ColumnId;
};

function isColumnId(value: string): value is ColumnId {
	return COLUMN_IDS.some((id) => id === value);
}

function emptyColumn(): LoanCard[] {
	return [];
}

let loans = $state<LoanCard[]>([
	{
		id: "loan-1",
		member: "Aoife Byrne",
		itemName: "Training feder",
		code: "item-000012",
		notes: "Wants it for Thursday longsword",
		column: "requested",
	},
	{
		id: "loan-2",
		member: "Ciarán Walsh",
		itemName: "Fencing mask",
		code: "item-000031",
		notes: "Size L if the spare is free",
		column: "requested",
	},
	{
		id: "loan-3",
		member: "Niamh Kelly",
		itemName: "350N jacket",
		code: "item-000044",
		notes: "Ready on the hall bench",
		column: "ready",
	},
	{
		id: "loan-4",
		member: "Séamus Doyle",
		itemName: "Club longsword",
		code: "item-000018",
		notes: "Out since last Saturday",
		column: "out",
	},
	{
		id: "loan-5",
		member: "Maeve Dunne",
		itemName: "Sparring gloves",
		code: "item-000055",
		notes: "Due back Monday",
		column: "overdue",
	},
]);

let lastDrop = $state("Nothing moved yet.");

const board = $derived(
	COLUMN_IDS.map((id) => ({
		id,
		label: COLUMN_LABELS[id],
		items: loans.filter((loan) => loan.column === id),
	})),
);

function handleDrop(state: DragDropState<LoanCard>) {
	const dragged = state.draggedItem;
	if (!dragged || !state.targetContainer) return;

	const without = loans.filter((loan) => loan.id !== dragged.id);
	let column: ColumnId;
	let indexInColumn: number;

	if (state.targetContainer.startsWith("card:")) {
		const targetId = state.targetContainer.slice("card:".length);
		const target = without.find((loan) => loan.id === targetId);
		if (!target) return;
		column = target.column;
		const columnItems = without.filter((loan) => loan.column === column);
		let index = columnItems.findIndex((loan) => loan.id === targetId);
		if (index === -1) index = columnItems.length;
		if (state.dropPosition === "after") index += 1;
		indexInColumn = index;
	} else if (isColumnId(state.targetContainer)) {
		column = state.targetContainer;
		indexInColumn = without.filter((loan) => loan.column === column).length;
	} else {
		return;
	}

	const moved = { ...dragged, column };
	const byColumn = {
		requested: emptyColumn(),
		ready: emptyColumn(),
		out: emptyColumn(),
		overdue: emptyColumn(),
	};
	for (const loan of without) {
		byColumn[loan.column].push(loan);
	}
	byColumn[column].splice(indexInColumn, 0, moved);
	loans = COLUMN_IDS.flatMap((id) => byColumn[id]);
	lastDrop = `Moved ${moved.itemName} (${moved.member}) to ${COLUMN_LABELS[column]}.`;
}
</script>

<section class="space-y-4">
	<div>
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			Quartermaster
		</p>
		<h2 class="font-heading text-3xl">Loan queue</h2>
		<p class="mt-2 max-w-2xl text-sm text-muted-foreground">
			Cross-container kanban. Drag a card into another column, or drop it
			before/after a card to change order. Pointer and touch should feel
			natural. Keyboard: Tab, Space, arrows — arrows stay in-column; the library
			has not shipped cross-column keyboard navigation yet.
		</p>
	</div>

	<div class="flex gap-4 overflow-x-auto pb-2">
		{#each board as column (column.id)}
			<div class="flex w-72 shrink-0 flex-col">
				<div class="mb-3 flex items-baseline justify-between gap-2">
					<h3 class="font-semibold">{column.label}</h3>
					<Badge variant="secondary">{column.items.length}</Badge>
				</div>
				<div
					class="flex min-h-64 flex-1 flex-col gap-3 rounded-2xl border border-border/80 bg-muted/30 p-3"
					use:droppable={{
						container: column.id,
						callbacks: { onDrop: handleDrop },
					}}
				>
					{#each column.items as loan (loan.id)}
						<Card.Root
							class="relative gap-3 py-4"
							{@attach attachDraggable(() => ({
								container: column.id,
								dragData: loan,
								keyboard: true,
							}))}
							{@attach attachDroppable<LoanCard>(() => ({
								container: `card:${loan.id}`,
								callbacks: { onDrop: handleDrop },
							}))}
						>
							<Card.Content>
								<p class="text-sm font-semibold">{loan.itemName}</p>
								<p class="mt-1 text-sm">{loan.member}</p>
								<div class="mt-2 flex flex-wrap items-center gap-2">
									<Badge variant="outline" class="font-mono">{loan.code}</Badge>
								</div>
								{#if loan.notes}
									<p class="mt-2 text-xs text-muted-foreground">
										Notes: {loan.notes}
									</p>
								{/if}
							</Card.Content>
						</Card.Root>
					{/each}
					{#if column.items.length === 0}
						<p class="py-8 text-center text-xs text-muted-foreground">
							Drop a request here
						</p>
					{/if}
				</div>
			</div>
		{/each}
	</div>

	<aside class="rounded-2xl border border-border/80 bg-muted/40 px-5 py-4">
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			In-memory state
		</p>
		<p class="mt-2 text-sm">{lastDrop}</p>
		<div class="mt-3 grid gap-3 sm:grid-cols-2">
			{#each board as column (column.id)}
				<div>
					<p class="text-sm font-semibold">
						{column.label}
						<span class="text-muted-foreground">({column.items.length})</span>
					</p>
					{#if column.items.length === 0}
						<p class="text-xs text-muted-foreground">Empty</p>
					{:else}
						<ol class="mt-1 space-y-1 text-sm">
							{#each column.items as loan, index (loan.id)}
								<li>
									<span class="font-mono text-xs text-muted-foreground"
										>{index + 1}.</span
									>
									{loan.itemName} — {loan.member}
								</li>
							{/each}
						</ol>
					{/if}
				</div>
			{/each}
		</div>
		<details class="mt-3">
			<summary class="cursor-pointer text-xs text-muted-foreground"
				>JSON snapshot</summary
			>
			<pre class="mt-2 overflow-x-auto text-xs">{JSON.stringify(
					loans,
					null,
					2,
				)}</pre>
		</details>
	</aside>
</section>
