<script lang="ts">
import type { HTMLAttributes } from "svelte/elements";
import type { WithElementRef, WithoutChildren } from "$lib/utils.js";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: WithoutChildren<WithElementRef<HTMLAttributes<HTMLSpanElement>>> = $props();
</script>

<span
	bind:this={ref}
	data-slot="breadcrumb-ellipsis"
	role="presentation"
	aria-hidden="true"
	class={cn("flex size-9 items-center justify-center", className)}
	{...restProps}
>
	<EllipsisIcon class="size-4" />
	<span class="sr-only">More</span>
</span>
