<!-- PROTOTYPE — throwaway -->
<script lang="ts">
import { dev } from "$app/environment";
import { goto } from "$app/navigation";
import { page } from "$app/state";
import { ChevronLeft, ChevronRight, FlaskConical } from "@lucide/svelte";
import { dndState } from "@thisux/sveltednd";

type Variant = {
	id: string;
	label: string;
};

let { variants, current }: { variants: Variant[]; current: string } = $props();

function selectVariant(index: number) {
	const variant = variants[(index + variants.length) % variants.length];
	if (!variant) return;
	const url = new URL(page.url);
	url.searchParams.set("variant", variant.id);
	void goto(`${url.pathname}${url.search}`, {
		replaceState: true,
		keepFocus: true,
		noScroll: true,
	});
}

function cycle(direction: -1 | 1) {
	selectVariant(
		variants.findIndex((variant) => variant.id === current) + direction,
	);
}

function handleKeydown(event: KeyboardEvent) {
	if (!dev) return;
	if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
	// sveltednd keyboard drag uses the same arrows — do not steal them.
	if (dndState.isDragging) return;

	const target = event.target;
	if (
		target instanceof HTMLElement &&
		target.matches("input, textarea, select, [contenteditable]")
	) {
		return;
	}

	event.preventDefault();
	cycle(event.key === "ArrowLeft" ? -1 : 1);
}
</script>

<svelte:window onkeydown={handleKeydown} />

{#if dev}
	{@const activeVariant = variants.find((variant) => variant.id === current)}
	<div
		class="fixed inset-x-3 bottom-[max(1rem,env(safe-area-inset-bottom))] z-50 mx-auto flex w-fit max-w-[calc(100%-1.5rem)] items-center gap-1 rounded-full border-2 border-[#ccff00] bg-zinc-950 px-2 py-2 text-[#ccff00] shadow-[0_8px_24px_rgba(0,0,0,0.45)]"
		aria-label="Prototype variation controls"
	>
		<FlaskConical class="ml-1 size-4" aria-hidden="true" />
		<button
			class="grid size-11 cursor-pointer place-items-center rounded-full transition-colors hover:bg-[#ccff00]/15 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#ccff00]"
			type="button"
			onclick={() => cycle(-1)}
			aria-label="Previous prototype variation"
		>
			<ChevronLeft class="size-5" aria-hidden="true" />
		</button>
		<span class="min-w-44 px-1 text-center text-sm font-bold tracking-wide">
			{activeVariant?.label ?? "Prototype"}
		</span>
		<button
			class="grid size-11 cursor-pointer place-items-center rounded-full transition-colors hover:bg-[#ccff00]/15 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#ccff00]"
			type="button"
			onclick={() => cycle(1)}
			aria-label="Next prototype variation"
		>
			<ChevronRight class="size-5" aria-hidden="true" />
		</button>
	</div>
{/if}
