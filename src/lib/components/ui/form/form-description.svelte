<script lang="ts">
import { cn } from "$lib/utils.js";
import type { HTMLAttributes } from "svelte/elements";

interface Props extends HTMLAttributes<HTMLParagraphElement> {
	ref?: HTMLParagraphElement | null;
}

let {
	ref = $bindable(null),
	class: className,
	children,
	...restProps
}: Props = $props();
</script>

<p
	bind:this={ref}
	data-slot="form-description"
	class={cn('text-muted-foreground text-sm', className)}
	{...restProps}
>
	{@render children?.()}
</p>
