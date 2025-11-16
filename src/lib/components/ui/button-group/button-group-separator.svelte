<script lang="ts">
import type { ComponentProps } from "svelte";
import type { Separator } from "$lib/components/ui/separator/index.js";

const {
	ref = $bindable(null),
	class: className,
	orientation = "vertical",
	...restProps
}: ComponentProps<typeof Separator> = $props();
</script>

<Separator
	bind:ref
	data-slot="button-group-separator"
	{orientation}
	class={cn("bg-input relative !m-0 self-stretch data-[orientation=vertical]:h-auto", className)}
	{...restProps}
/>
