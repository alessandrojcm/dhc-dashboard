<script lang="ts">
import type { ComponentProps } from "svelte";
import type { Separator } from "$lib/components/ui/separator/index.js";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: ComponentProps<typeof Separator> = $props();
</script>

<Separator
	bind:ref
	data-slot="sidebar-separator"
	data-sidebar="separator"
	class={cn("bg-sidebar-border", className)}
	{...restProps}
/>
