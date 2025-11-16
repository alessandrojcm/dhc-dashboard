<script lang="ts">
import type * as FormPrimitive from "formsnap";
import type { WithoutChild } from "$lib/utils.js";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: WithoutChild<FormPrimitive.DescriptionProps> = $props();
</script>

<FormPrimitive.Description
	bind:ref
	data-slot="form-description"
	class={cn("text-muted-foreground text-sm", className)}
	{...restProps}
/>
