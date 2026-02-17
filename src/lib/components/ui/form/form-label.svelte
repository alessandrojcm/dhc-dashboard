<script lang="ts">
import { cn } from "$lib/utils.js";
import type { HTMLLabelAttributes } from "svelte/elements";

interface Props extends HTMLLabelAttributes {
	ref?: HTMLLabelElement | null;
	hasError?: boolean;
}

let {
	ref = $bindable(null),
	children,
	class: className,
	hasError = false,
	...restProps
}: Props = $props();
</script>

<label
	bind:this={ref}
	data-slot="form-label"
	class={cn(
		'text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70',
		hasError && 'text-destructive',
		className
	)}
	{...restProps}
>
	{@render children?.()}
</label>
