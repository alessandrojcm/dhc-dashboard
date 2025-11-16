<script lang="ts">
import type { AlertDialog as AlertDialogPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: AlertDialogPrimitive.CancelProps = $props();
</script>

<AlertDialogPrimitive.Cancel
	bind:ref
	data-slot="alert-dialog-cancel"
	class={cn(buttonVariants({ variant: "outline" }), className)}
	{...restProps}
/>
