<script lang="ts">
import type { Drawer as DrawerPrimitive } from "vaul-svelte";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: DrawerPrimitive.TitleProps = $props();
</script>

<DrawerPrimitive.Title
	bind:ref
	data-slot="drawer-title"
	class={cn("text-foreground font-semibold", className)}
	{...restProps}
/>
