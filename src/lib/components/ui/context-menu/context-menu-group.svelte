<script lang="ts">
import type { ContextMenu as ContextMenuPrimitive } from "bits-ui";

const { ref = $bindable(null), ...restProps }: ContextMenuPrimitive.GroupProps =
	$props();
</script>

<ContextMenuPrimitive.Group bind:ref data-slot="context-menu-group" {...restProps} />
