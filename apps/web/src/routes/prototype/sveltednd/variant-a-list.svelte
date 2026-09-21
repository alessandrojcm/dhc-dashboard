<!-- PROTOTYPE — throwaway. VariantA — Sortable list -->
<script lang="ts">
import { Badge } from "$lib/components/ui/badge/index.js";
import * as Card from "$lib/components/ui/card/index.js";
import { GripVertical } from "@lucide/svelte";
import {
	attachDraggable,
	attachDroppable,
	type DragDropState,
} from "@thisux/sveltednd";

type WaitlistItem = {
	id: string;
	name: string;
	code: string;
	notes: string;
};

let items = $state<WaitlistItem[]>([
	{
		id: "feder",
		name: "Training feder",
		code: "item-000012",
		notes: "Slightly bent tip — still fine for drills",
	},
	{
		id: "longsword",
		name: "Club longsword",
		code: "item-000018",
		notes: "Needs a fresh leather wrap",
	},
	{
		id: "mask",
		name: "Fencing mask",
		code: "item-000031",
		notes: "Size L, Saturday pair work",
	},
	{
		id: "jacket",
		name: "350N jacket",
		code: "item-000044",
		notes: "Club spare on the waitlist pile",
	},
	{
		id: "gloves",
		name: "Sparring gloves",
		code: "item-000055",
		notes: "Pair — go out after the mask",
	},
	{
		id: "gorget",
		name: "Gorget",
		code: "item-000061",
		notes: "Last on the training-order list",
	},
]);

let lastDrop = $state("Nothing moved yet.");

function handleDrop(state: DragDropState<WaitlistItem>) {
	const { draggedItem, targetContainer, dropPosition } = state;
	const dragIndex = items.findIndex((item) => item.id === draggedItem.id);
	let dropIndex = Number.parseInt(targetContainer ?? "0", 10);
	if (dropPosition === "after") dropIndex += 1;
	if (dragIndex === -1 || Number.isNaN(dropIndex)) return;

	const next = [...items];
	const [item] = next.splice(dragIndex, 1);
	if (!item) return;
	next.splice(dragIndex < dropIndex ? dropIndex - 1 : dropIndex, 0, item);
	items = next;
	lastDrop = `Moved ${item.name} to place ${next.findIndex((row) => row.id === item.id) + 1}.`;
}
</script>

<section class="space-y-4">
	<div>
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			Quartermaster
		</p>
		<h2 class="font-heading text-3xl">Saturday training order</h2>
		<p class="mt-2 max-w-2xl text-sm text-muted-foreground">
			Simple vertical reorder next to shadcn cards. Try the grip with a pointer,
			Tab then Space/Enter and arrows on the keyboard, and a finger on touch.
			Escape cancels a keyboard lift.
		</p>
	</div>

	<ol class="space-y-3" aria-label="Training-order list">
		{#each items as item, index (item.id)}
			<li>
				<Card.Root
					class="relative gap-3 py-4"
					{@attach attachDraggable(() => ({
						container: index.toString(),
						dragData: item,
						handle: ".drag-handle",
						keyboard: true,
					}))}
					{@attach attachDroppable<WaitlistItem>(() => ({
						container: index.toString(),
						callbacks: { onDrop: handleDrop },
					}))}
				>
					<Card.Content class="flex items-start gap-3">
						<span
							class="drag-handle mt-0.5 inline-flex cursor-grab text-muted-foreground"
							aria-hidden="true"
						>
							<GripVertical class="size-5" />
						</span>
						<div class="min-w-0 flex-1">
							<div class="flex flex-wrap items-center gap-2">
								<span class="font-mono text-xs text-muted-foreground"
									>{String(index + 1).padStart(2, "0")}</span
								>
								<p class="font-semibold">{item.name}</p>
								<Badge variant="outline" class="font-mono">{item.code}</Badge>
							</div>
							<p class="mt-1 text-sm text-muted-foreground">{item.notes}</p>
						</div>
					</Card.Content>
				</Card.Root>
			</li>
		{/each}
	</ol>

	<aside class="rounded-2xl border border-border/80 bg-muted/40 px-5 py-4">
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			In-memory state
		</p>
		<p class="mt-2 text-sm">{lastDrop}</p>
		<ol class="mt-3 space-y-1 text-sm">
			{#each items as item, index (item.id)}
				<li>
					<span class="font-mono text-xs text-muted-foreground"
						>{index + 1}.</span
					>
					{item.name}
					<span class="font-mono text-xs text-muted-foreground"
						>{item.code}</span
					>
				</li>
			{/each}
		</ol>
		<details class="mt-3">
			<summary class="cursor-pointer text-xs text-muted-foreground"
				>JSON snapshot</summary
			>
			<pre class="mt-2 overflow-x-auto text-xs">{JSON.stringify(
					items,
					null,
					2,
				)}</pre>
		</details>
	</aside>
</section>
