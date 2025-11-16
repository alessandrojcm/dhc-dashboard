<script lang="ts">
import type { ContextMenu as ContextMenuPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: ContextMenuPrimitive.SeparatorProps = $props();
</script>

<ContextMenuPrimitive.Separator
	bind:ref
	data-slot="context-menu-separator"
	class={cn("bg-border -mx-1 my-1 h-px", className)}
	{...restProps}
/>
