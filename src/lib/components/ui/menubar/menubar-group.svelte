<script lang="ts">
import type { Menubar as MenubarPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	...restProps
}: MenubarPrimitive.GroupProps & {
	inset?: boolean;
} = $props();
</script>

<MenubarPrimitive.Group bind:ref data-slot="menubar-group" {...restProps} />
