<!--
	PROTOTYPE — throwaway
	Three structurally different @thisux/sveltednd interaction models, switchable via `?variant=`, on throwaway `/prototype/sveltednd`.
-->
<script lang="ts">
import { page } from "$app/state";
import PrototypeSwitcher from "$lib/components/ui/prototype-switcher.svelte";
import { dndState } from "@thisux/sveltednd";
import VariantA from "./variant-a-list.svelte";
import VariantB from "./variant-b-nested.svelte";
import VariantC from "./variant-c-kanban.svelte";

const variants = [
	{ id: "A", label: "A — Sortable list" },
	{ id: "B", label: "B — Nested containers" },
	{ id: "C", label: "C — Cross-container kanban" },
];

const rawVariant = $derived(page.url.searchParams.get("variant") ?? "A");
const current = $derived(
	variants.some((variant) => variant.id === rawVariant) ? rawVariant : "A",
);
</script>

<svelte:head>
	<title>sveltednd prototype | Dublin HEMA Club</title>
</svelte:head>

<div class="mx-auto max-w-6xl space-y-6 p-4 pb-32 sm:p-6 lg:p-10">
	<section
		class="rounded-2xl border-2 border-dashed border-[#ccff00] bg-zinc-950 px-5 py-4 text-[#ccff00] shadow-[0_8px_24px_rgba(0,0,0,0.25)]"
	>
		<p class="text-xs font-bold tracking-[0.16em] uppercase">
			PROTOTYPE — throwaway
		</p>
		<h1 class="mt-2 font-heading text-2xl leading-tight sm:text-3xl">
			Does @thisux/sveltednd feel right here?
		</h1>
		<p class="mt-3 max-w-3xl text-sm leading-relaxed text-[#ccff00]/80">
			Assumption: this answers library fitness and interaction structure, not a
			visual redesign. There is no existing drag-and-drop UI. Inventory pages
			are production and require <code class="font-mono">inventory.manage</code
			>, so this is a throwaway route (sub-shape B).
		</p>
		<p class="mt-3 text-sm text-[#ccff00]/80">
			Open <code class="font-mono"
				>https://127.0.0.1:5173/prototype/sveltednd</code
			>
			after <code class="font-mono">mise run dev</code>. Share a variant with
			<code class="font-mono">?variant=A</code>,
			<code class="font-mono">B</code>, or
			<code class="font-mono">C</code>.
		</p>
	</section>

	<section
		class="rounded-2xl border border-border/80 bg-card px-5 py-4 shadow-[var(--shadow-block)]"
		aria-live="polite"
	>
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			Live dndState
		</p>
		{#if dndState.isDragging}
			<dl class="mt-3 grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
				<div>
					<dt class="text-muted-foreground">Dragging</dt>
					<dd class="font-mono text-xs">
						{JSON.stringify(dndState.draggedItem)}
					</dd>
				</div>
				<div>
					<dt class="text-muted-foreground">From</dt>
					<dd class="font-mono text-xs">{dndState.sourceContainer || "—"}</dd>
				</div>
				<div>
					<dt class="text-muted-foreground">Over</dt>
					<dd class="font-mono text-xs">
						{dndState.targetContainer ?? "—"}
					</dd>
				</div>
				<div>
					<dt class="text-muted-foreground">Position</dt>
					<dd>{dndState.dropPosition ?? "—"}</dd>
				</div>
				<div>
					<dt class="text-muted-foreground">Input</dt>
					<dd>{dndState.dragInput ?? "—"}</dd>
				</div>
				<div>
					<dt class="text-muted-foreground">Group</dt>
					<dd>{String(dndState.sourceContainerGroup ?? "—")}</dd>
				</div>
			</dl>
		{:else}
			<p class="mt-2 text-sm text-muted-foreground">
				Idle — pick up gear to watch the library state while dragging.
			</p>
		{/if}
	</section>

	{#if current === "B"}
		<VariantB />
	{:else if current === "C"}
		<VariantC />
	{:else}
		<VariantA />
	{/if}
</div>

<PrototypeSwitcher {variants} {current} />

<style>
:global(.dragging) {
	opacity: 0.55;
}

:global(.drag-over) {
	outline: 2px dashed var(--color-primary, #1f4f85);
	outline-offset: 2px;
}

:global(.drop-before::before),
:global(.drop-after::after) {
	background-color: var(--color-secondary, #e5b524);
}
</style>
