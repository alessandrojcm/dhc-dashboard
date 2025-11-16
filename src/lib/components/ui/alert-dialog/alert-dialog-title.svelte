<script lang="ts">
import type { AlertDialog as AlertDialogPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: AlertDialogPrimitive.TitleProps = $props();
</script>

<AlertDialogPrimitive.Title
	bind:ref
	data-slot="alert-dialog-title"
	class={cn("text-lg font-semibold", className)}
	{...restProps}
/>
