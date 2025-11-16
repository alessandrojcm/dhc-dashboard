<script lang="ts">
import type { ContextMenu as ContextMenuPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	...restProps
}: ContextMenuPrimitive.TriggerProps = $props();
</script>

<ContextMenuPrimitive.Trigger bind:ref data-slot="context-menu-trigger" {...restProps} />
