<script lang="ts">
import type { AlertDialog as AlertDialogPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: AlertDialogPrimitive.ActionProps = $props();
</script>

<AlertDialogPrimitive.Action
	bind:ref
	data-slot="alert-dialog-action"
	class={cn(buttonVariants(), className)}
	{...restProps}
/>
