<script lang="ts">
import type { Drawer as DrawerPrimitive } from "vaul-svelte";

const { ref = $bindable(null), ...restProps }: DrawerPrimitive.CloseProps =
	$props();
</script>

<DrawerPrimitive.Close bind:ref data-slot="drawer-close" {...restProps} />
