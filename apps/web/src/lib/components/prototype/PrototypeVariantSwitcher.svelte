<script lang="ts">
import { goto } from "$app/navigation";
import { page } from "$app/state";
import { Button } from "#lib/components/ui/button/index.js";
import { ChevronLeft, ChevronRight, FlaskConical } from "@lucide/svelte";

type Variant = {
	id: string;
	label: string;
};

let { variants, current }: { variants: Variant[]; current: string } = $props();

function selectVariant(index: number) {
	const variant = variants[(index + variants.length) % variants.length];
	const url = new URL(page.url.href);
	url.searchParams.set("variant", variant.id);
	void goto(`${url.pathname}${url.search}`, {
		replace: true,
		reset: false,
	});
}

function cycle(direction: -1 | 1) {
	selectVariant(
		variants.findIndex((variant) => variant.id === current) + direction,
	);
}

function handleKeydown(event: KeyboardEvent) {
	if (!import.meta.env.DEV) return;

	const target = event.target;
	if (
		(target instanceof HTMLElement &&
			target.matches("input, textarea, select, [contenteditable='true']")) ||
		(event.key !== "ArrowLeft" && event.key !== "ArrowRight")
	) {
		return;
	}

	event.preventDefault();
	cycle(event.key === "ArrowLeft" ? -1 : 1);
}
</script>

<svelte:window onkeydown={handleKeydown} />

{#if import.meta.env.DEV}
	{@const activeVariant = variants.find((variant) => variant.id === current)}
	<div
		class="fixed inset-x-3 bottom-[max(1rem,env(safe-area-inset-bottom))] z-50 mx-auto flex w-fit max-w-[calc(100%-1.5rem)] items-center gap-1 rounded-full border border-primary/30 bg-primary px-2 py-2 text-primary-foreground shadow-lg"
		aria-label="Prototype variation controls"
	>
		<FlaskConical class="ml-1 size-4" aria-hidden="true" />
		<Button
			variant="ghost"
			size="icon"
			class="rounded-full hover:bg-primary-foreground/15 hover:text-primary-foreground"
			onclick={() => cycle(-1)}
			aria-label="Previous prototype variation"
		>
			<ChevronLeft class="size-5" aria-hidden="true" />
		</Button>
		<span class="min-w-36 px-1 text-center text-sm font-semibold">
			{activeVariant?.label ?? "Prototype"}
		</span>
		<Button
			variant="ghost"
			size="icon"
			class="rounded-full hover:bg-primary-foreground/15 hover:text-primary-foreground"
			onclick={() => cycle(1)}
			aria-label="Next prototype variation"
		>
			<ChevronRight class="size-5" aria-hidden="true" />
		</Button>
	</div>
{/if}
