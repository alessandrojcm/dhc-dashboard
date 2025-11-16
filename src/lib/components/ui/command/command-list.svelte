<script lang="ts">
import type { Command as CommandPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: CommandPrimitive.ListProps = $props();
</script>

<CommandPrimitive.List
	bind:ref
	data-slot="command-list"
	class={cn("max-h-[300px] scroll-py-1 overflow-y-auto overflow-x-hidden", className)}
	{...restProps}
/>
