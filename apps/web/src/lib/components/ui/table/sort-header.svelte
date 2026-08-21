<script lang="ts">
import type { SortDirection } from "@tanstack/table-core";
import type { ComponentProps } from "svelte";
import { Button } from "$lib/components/ui/button/index.js";
import { ArrowDown, ArrowUp, ArrowUpDown } from "@lucide/svelte";

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

<Button
	{variant}
	aria-label={`Sort by ${header}${sortDirection ? `, currently ${sortDirection === "asc" ? "ascending" : "descending"}` : ""}`}
	{...restProps}
>
	<span>{header}</span>
	<span aria-hidden="true">
		{#if sortDirection === "asc"}
			<ArrowUp class="size-4" />
		{:else if sortDirection === "desc"}
			<ArrowDown class="size-4" />
		{:else}
			<ArrowUpDown class="size-4" />
		{/if}
	</span>
</Button>
