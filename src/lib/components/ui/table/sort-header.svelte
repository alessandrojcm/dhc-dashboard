<script lang="ts">
import type { SortDirection } from "@tanstack/table-core";
import type { ComponentProps } from "svelte";
import type { Button } from "$lib/components/ui/button/index.js";

const {
	variant = "ghost",
	header,
	sortDirection,
	...restProps
}: ComponentProps<typeof Button> & {
	header: string;
	sortDirection?: SortDirection | false;
} = $props();
</script>

<span class="flex items-center gap-2">
	{header}
	<Button {variant} {...restProps}>
		{#if sortDirection === 'asc'}
			<ArrowUp class="size-4" />
		{:else if sortDirection === 'desc'}
			<ArrowDown class="size-4" />
		{:else}
			<ArrowUpDown class="size-4" />
		{/if}
	</Button>
</span>
