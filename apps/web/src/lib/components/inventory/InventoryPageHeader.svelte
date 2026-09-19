<script lang="ts">
import type { Component } from "svelte";
import { cn } from "$lib/utils.js";

let {
	eyebrow,
	title,
	description,
	icon: Icon,
	actions,
	class: className,
}: {
	eyebrow: string;
	title: string;
	description?: string;
	icon?: Component<{ class?: string }>;
	actions?: import("svelte").Snippet;
	class?: string;
} = $props();
</script>

<header class={cn("inventory-page-header", className)}>
	<div class="flex min-w-0 items-start gap-3 sm:gap-4">
		{#if Icon}
			<div class="inventory-page-header__icon" aria-hidden="true">
				<Icon class="size-6" />
			</div>
		{/if}
		<div class="min-w-0">
			<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
				{eyebrow}
			</p>
			<h1 class="font-heading text-3xl leading-tight font-bold sm:text-4xl">
				{title}
			</h1>
			{#if description}<p
					class="mt-2 max-w-2xl text-sm leading-relaxed text-muted-foreground sm:text-base"
				>
					{description}
				</p>{/if}
		</div>
	</div>
	{#if actions}
		<div class="shrink-0">{@render actions()}</div>
	{/if}
</header>
