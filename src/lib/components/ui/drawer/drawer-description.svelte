<script lang="ts">
import type { Drawer as DrawerPrimitive } from "vaul-svelte";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: DrawerPrimitive.DescriptionProps = $props();
</script>

<DrawerPrimitive.Description
	bind:ref
	data-slot="drawer-description"
	class={cn("text-muted-foreground text-sm", className)}
	{...restProps}
/>
