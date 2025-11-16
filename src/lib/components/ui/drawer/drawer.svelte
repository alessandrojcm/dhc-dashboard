<script lang="ts">
import type { Drawer as DrawerPrimitive } from "vaul-svelte";

const {
	shouldScaleBackground = true,
	open = $bindable(false),
	activeSnapPoint = $bindable(null),
	...restProps
}: DrawerPrimitive.RootProps = $props();
</script>

<DrawerPrimitive.Root {shouldScaleBackground} bind:open bind:activeSnapPoint {...restProps} />
