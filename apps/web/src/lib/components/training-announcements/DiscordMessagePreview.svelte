<!--
	Discord rendering of one Training Announcement, as the preview endpoint
	returned it (ALE-330). The text is Phoenix's `Copy.render/2` output, never a
	local re-render, so what a committee member reads here is exactly what
	members will see — including the `@everyone` line the mention setting adds.
-->
<script lang="ts">
import { MessageSquareText } from "@lucide/svelte";

let {
	channelLabel,
	renderedMessage,
	threadName,
}: {
	channelLabel: string;
	renderedMessage: string;
	threadName?: string | null;
} = $props();

const lines = $derived(renderedMessage.split("\n"));
</script>

<div
	class="rounded-2xl border border-border/70 bg-muted/35 p-3 text-sm"
	role="group"
	aria-label="Discord preview"
>
	<p
		class="mb-2 text-[0.6875rem] font-bold tracking-[0.1em] text-muted-foreground uppercase"
	>
		Posts in the {channelLabel.toLowerCase()}
	</p>
	<div class="flex gap-3">
		<div
			class="mt-0.5 grid size-9 flex-none place-items-center rounded-full bg-primary text-xs font-black text-primary-foreground"
			aria-hidden="true"
		>
			DHC
		</div>
		<div class="min-w-0 flex-1">
			<div class="flex items-baseline gap-2">
				<span class="font-bold">Dublin HEMA Club</span>
				<span
					class="rounded bg-primary/15 px-1 text-[0.625rem] font-black tracking-wide text-primary uppercase"
					>bot</span
				>
			</div>
			<p class="mt-0.5 leading-relaxed break-words whitespace-pre-wrap">
				{#each lines as line, index (index)}
					{#if line === "@everyone"}
						<span class="rounded bg-primary/20 px-1 font-semibold text-primary"
							>@everyone</span
						>{:else}{line}{/if}{#if index < lines.length - 1}{"\n"}{/if}
				{/each}
			</p>
			{#if threadName}
				<div
					class="mt-2 inline-flex max-w-full items-center gap-1.5 rounded-lg border border-border/70 bg-background/70 px-2 py-1 text-xs font-semibold"
				>
					<MessageSquareText class="size-3.5 flex-none" aria-hidden="true" />
					<span class="truncate">{threadName}</span>
					<span class="text-muted-foreground">· thread, 24 h auto-archive</span>
				</div>
			{/if}
		</div>
	</div>
</div>
