<!-- PROTOTYPE — throwaway. Discord-style rendering of a Training Occurrence message. -->
<script lang="ts">
import { Hash, MessageSquareText } from "@lucide/svelte";

let {
	channel,
	rendered,
	threadName,
	compact = false,
	muted = false,
}: {
	channel: string;
	rendered: string;
	threadName?: string;
	compact?: boolean;
	muted?: boolean;
} = $props();

const lines = $derived(rendered.split("\n"));
</script>

<div
	class="discord-preview rounded-xl border border-border/70 p-3 text-sm"
	class:opacity-60={muted}
	class:discord-preview--compact={compact}
>
	<div
		class="mb-2 flex items-center gap-1 text-[0.6875rem] font-bold tracking-[0.1em] text-muted-foreground uppercase"
	>
		<Hash aria-hidden="true" class="size-3" />
		{channel.replace(/^#/, "")}
	</div>
	<div class="flex gap-3">
		<div
			class="mt-0.5 flex size-9 flex-none items-center justify-center rounded-full bg-primary text-xs font-black text-primary-foreground"
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
						>
					{:else}
						{line}
					{/if}
					{#if index < lines.length - 1}
						{"\n"}
					{/if}
				{/each}
			</p>
			{#if threadName}
				<div
					class="mt-2 inline-flex max-w-full items-center gap-1.5 rounded-lg border border-border/70 bg-muted/40 px-2 py-1 text-xs font-semibold"
				>
					<MessageSquareText aria-hidden="true" class="size-3.5 flex-none" />
					<span class="truncate">{threadName}</span>
					<span class="text-muted-foreground">· thread, 24 h auto-archive</span>
				</div>
			{/if}
		</div>
	</div>
</div>

<style>
.discord-preview {
	background: hsl(var(--muted) / 0.35);
}

.discord-preview--compact p {
	font-size: 0.8125rem;
}
</style>
