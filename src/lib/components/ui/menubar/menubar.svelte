<script lang="ts">
import type { Menubar as MenubarPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: MenubarPrimitive.RootProps = $props();
</script>

<MenubarPrimitive.Root
	bind:ref
	data-slot="menubar"
	class={cn(
		"bg-background shadow-xs flex h-9 items-center gap-1 rounded-md border p-1",
		className
	)}
	{...restProps}
/>
