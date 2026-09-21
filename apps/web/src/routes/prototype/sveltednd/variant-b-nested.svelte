<!-- PROTOTYPE — throwaway. VariantB — Nested containers -->
<script lang="ts">
import { Badge } from "$lib/components/ui/badge/index.js";
import * as Card from "$lib/components/ui/card/index.js";
import { Folder, GripVertical, Package } from "@lucide/svelte";
import { draggable, droppable, type DragDropState } from "@thisux/sveltednd";

type GearItem = {
	kind: "item";
	id: string;
	name: string;
	code: string;
	notes: string;
};

type GearContainer = {
	kind: "container";
	id: string;
	name: string;
	children: GearNode[];
};

type GearNode = GearItem | GearContainer;

type NestedDrag =
	| { kind: "item"; item: GearItem }
	| { kind: "container"; box: GearContainer };

type Location = {
	parent: GearContainer | null;
	index: number;
	node: GearNode;
};

let tree = $state<GearContainer[]>([
	{
		kind: "container",
		id: "hall-cupboard",
		name: "Hall cupboard",
		children: [
			{
				kind: "container",
				id: "longsword-crate",
				name: "Longsword crate",
				children: [
					{
						kind: "item",
						id: "feder-1",
						name: "Training feder",
						code: "item-000012",
						notes: "Slightly bent tip",
					},
					{
						kind: "item",
						id: "longsword-1",
						name: "Club longsword",
						code: "item-000018",
						notes: "Needs leather wrap",
					},
				],
			},
			{
				kind: "container",
				id: "mask-crate",
				name: "Mask crate",
				children: [
					{
						kind: "item",
						id: "mask-1",
						name: "Fencing mask",
						code: "item-000031",
						notes: "Size L",
					},
				],
			},
			{
				kind: "item",
				id: "jacket-1",
				name: "350N jacket",
				code: "item-000044",
				notes: "Club spare",
			},
		],
	},
	{
		kind: "container",
		id: "match-bag",
		name: "Match-day bag",
		children: [
			{
				kind: "item",
				id: "gloves-1",
				name: "Sparring gloves",
				code: "item-000055",
				notes: "Pair",
			},
			{
				kind: "item",
				id: "gorget-1",
				name: "Gorget",
				code: "item-000061",
				notes: "",
			},
		],
	},
]);

let lastDrop = $state("Nothing moved yet.");

function findIn(
	nodes: GearNode[],
	id: string,
	parent: GearContainer | null,
): Location | null {
	for (let index = 0; index < nodes.length; index += 1) {
		const node = nodes[index];
		if (!node) continue;
		if (node.id === id) return { parent, index, node };
		if (node.kind === "container") {
			const nested = findIn(node.children, id, node);
			if (nested) return nested;
		}
	}
	return null;
}

function findLocation(id: string): Location | null {
	return findIn(tree, id, null);
}

function findContainer(id: string): GearContainer | null {
	const location = findLocation(id);
	return location?.node.kind === "container" ? location.node : null;
}

function isDescendant(box: GearContainer, id: string): boolean {
	return box.children.some(
		(child) =>
			child.id === id ||
			(child.kind === "container" && isDescendant(child, id)),
	);
}

function takeNode(id: string): GearNode | null {
	const location = findLocation(id);
	if (!location) return null;
	const siblings = location.parent ? location.parent.children : tree;
	const [removed] = siblings.splice(location.index, 1);
	return removed ?? null;
}

function insertChild(parent: GearContainer, node: GearNode, index: number) {
	parent.children = [
		...parent.children.slice(0, index),
		node,
		...parent.children.slice(index),
	];
}

function handleItemDrop(state: DragDropState<NestedDrag>) {
	const { draggedItem, targetContainer, dropPosition } = state;
	if (!draggedItem || draggedItem.kind !== "item" || !targetContainer) return;

	let dest:
		| { mode: "append"; id: string }
		| { mode: "item"; id: string; after: boolean }
		| null = null;

	if (targetContainer.startsWith("list:")) {
		dest = { mode: "append", id: targetContainer.slice("list:".length) };
	} else if (targetContainer.startsWith("item:")) {
		const targetId = targetContainer.slice("item:".length);
		if (targetId === draggedItem.item.id) return;
		dest = { mode: "item", id: targetId, after: dropPosition === "after" };
	} else if (targetContainer.startsWith("container:")) {
		dest = {
			mode: "append",
			id: targetContainer.slice("container:".length),
		};
	}
	if (!dest) return;

	const removed = takeNode(draggedItem.item.id);
	if (!removed || removed.kind !== "item") return;

	if (dest.mode === "append") {
		const parent = findContainer(dest.id);
		if (!parent) return;
		insertChild(parent, removed, parent.children.length);
		lastDrop = `Moved ${removed.name} into ${parent.name}.`;
	} else {
		const location = findLocation(dest.id);
		if (!location?.parent) return;
		const index = dest.after ? location.index + 1 : location.index;
		insertChild(location.parent, removed, index);
		lastDrop = `Moved ${removed.name} into ${location.parent.name}.`;
	}
	tree = [...tree];
}

function handleContainerDrop(state: DragDropState<NestedDrag>) {
	const { draggedItem, targetContainer, dropPosition } = state;
	if (!draggedItem || draggedItem.kind !== "container" || !targetContainer) {
		return;
	}

	const draggedId = draggedItem.box.id;
	let mode: "nest" | "before" | "after" = "nest";
	let targetId = "";

	if (targetContainer.startsWith("nest:")) {
		targetId = targetContainer.slice("nest:".length);
		mode = "nest";
	} else if (targetContainer.startsWith("container:")) {
		targetId = targetContainer.slice("container:".length);
		mode =
			dropPosition === "after"
				? "after"
				: dropPosition === "before"
					? "before"
					: "nest";
	} else {
		return;
	}

	if (!targetId || targetId === draggedId) return;
	const targetBox = findContainer(targetId);
	const draggedBox = findContainer(draggedId);
	if (!targetBox || !draggedBox) return;
	if (isDescendant(draggedBox, targetId)) return;

	const removed = takeNode(draggedId);
	if (!removed || removed.kind !== "container") return;

	if (mode === "nest") {
		const nestInto = findContainer(targetId);
		if (!nestInto) return;
		nestInto.children = [...nestInto.children, removed];
		lastDrop = `Nested ${removed.name} inside ${nestInto.name}.`;
	} else {
		const location = findLocation(targetId);
		if (!location) return;
		const siblings = location.parent ? location.parent.children : tree;
		let index = location.index;
		if (mode === "after") index += 1;
		siblings.splice(index, 0, removed);
		lastDrop = `Moved ${removed.name} ${mode} ${targetBox.name}.`;
	}

	tree = [...tree];
}

function flatten(
	nodes: GearNode[],
	depth = 0,
): { label: string; meta: string }[] {
	return nodes.flatMap((node) => {
		const pad = "· ".repeat(depth);
		if (node.kind === "container") {
			return [
				{ label: `${pad}${node.name}`, meta: "container" },
				...flatten(node.children, depth + 1),
			];
		}
		return [{ label: `${pad}${node.name}`, meta: node.code }];
	});
}

const rows = $derived(flatten(tree));
</script>

<section class="space-y-4">
	<div>
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			Quartermaster
		</p>
		<h2 class="font-heading text-3xl">Hall storage</h2>
		<p class="mt-2 max-w-2xl text-sm text-muted-foreground">
			Nested containers with <code class="font-mono">containerGroup</code>. Move
			items between crates, nest a crate inside the cupboard, or reorder
			containers. Pointer, keyboard (Space then arrows), and touch. A container
			cannot drop into itself.
		</p>
	</div>

	<div class="space-y-4">
		{#snippet storageTree(nodes: GearNode[])}
			{#each nodes as node (node.id)}
				{#if node.kind === "container"}
					<div
						class="rounded-2xl border border-border/80 bg-card p-3 shadow-[var(--shadow-block)]"
						use:droppable={{
							container: `container:${node.id}`,
							containerGroup: "container",
							callbacks: { onDrop: handleContainerDrop },
						}}
					>
						<div
							class="mb-3 flex items-start gap-2"
							use:draggable={{
								container: `container:${node.id}`,
								containerGroup: "container",
								dragData: { kind: "container", box: node } satisfies NestedDrag,
								handle: ".container-handle",
								keyboard: true,
							}}
						>
							<span
								class="container-handle mt-0.5 inline-flex cursor-grab text-muted-foreground"
								aria-hidden="true"
							>
								<GripVertical class="size-5" />
							</span>
							<Folder class="mt-0.5 size-5 text-primary" aria-hidden="true" />
							<div class="min-w-0 flex-1">
								<p class="font-semibold">{node.name}</p>
								<p class="text-xs text-muted-foreground">Container</p>
							</div>
						</div>

						<div class="space-y-2 pl-4">
							{@render storageTree(node.children)}

							<div
								class="rounded-xl border border-dashed border-border px-3 py-2 text-xs text-muted-foreground"
								use:droppable={{
									container: `list:${node.id}`,
									containerGroup: "item",
									callbacks: { onDrop: handleItemDrop },
								}}
							>
								Drop gear into {node.name}
							</div>
							<div
								class="rounded-xl border border-dashed border-primary/40 px-3 py-2 text-xs text-muted-foreground"
								use:droppable={{
									container: `nest:${node.id}`,
									containerGroup: "container",
									callbacks: { onDrop: handleContainerDrop },
								}}
							>
								Nest a container inside {node.name}
							</div>
						</div>
					</div>
				{:else}
					<div
						use:droppable={{
							container: `item:${node.id}`,
							containerGroup: "item",
							callbacks: { onDrop: handleItemDrop },
						}}
						use:draggable={{
							container: `item:${node.id}`,
							containerGroup: "item",
							dragData: { kind: "item", item: node } satisfies NestedDrag,
							handle: ".item-handle",
							keyboard: true,
						}}
					>
						<Card.Root class="relative gap-3 py-3">
							<Card.Content class="flex items-start gap-3">
								<span
									class="item-handle mt-0.5 inline-flex cursor-grab text-muted-foreground"
									aria-hidden="true"
								>
									<GripVertical class="size-4" />
								</span>
								<Package
									class="mt-0.5 size-4 text-muted-foreground"
									aria-hidden="true"
								/>
								<div class="min-w-0 flex-1">
									<div class="flex flex-wrap items-center gap-2">
										<p class="text-sm font-semibold">{node.name}</p>
										<Badge variant="outline" class="font-mono"
											>{node.code}</Badge
										>
									</div>
									{#if node.notes}
										<p class="mt-1 text-xs text-muted-foreground">
											Notes: {node.notes}
										</p>
									{/if}
								</div>
							</Card.Content>
						</Card.Root>
					</div>
				{/if}
			{/each}
		{/snippet}

		{@render storageTree(tree)}
	</div>

	<aside class="rounded-2xl border border-border/80 bg-muted/40 px-5 py-4">
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			In-memory state
		</p>
		<p class="mt-2 text-sm">{lastDrop}</p>
		<ul class="mt-3 space-y-1 font-mono text-sm">
			{#each rows as row, index (`${row.label}-${index}`)}
				<li>
					{row.label}
					<span class="text-xs text-muted-foreground">{row.meta}</span>
				</li>
			{/each}
		</ul>
		<details class="mt-3">
			<summary class="cursor-pointer text-xs text-muted-foreground"
				>JSON snapshot</summary
			>
			<pre class="mt-2 overflow-x-auto text-xs">{JSON.stringify(
					tree,
					null,
					2,
				)}</pre>
		</details>
	</aside>
</section>
