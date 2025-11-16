<script lang="ts">
import type { ContextMenu as ContextMenuPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	class: className,
	inset,
	...restProps
}: ContextMenuPrimitive.GroupHeadingProps & {
	inset?: boolean;
} = $props();
</script>

<ContextMenuPrimitive.GroupHeading
	bind:ref
	data-slot="context-menu-group-heading"
	data-inset={inset}
	class={cn("text-foreground px-2 py-1.5 text-sm font-medium data-[inset]:pl-8", className)}
	{...restProps}
/>
