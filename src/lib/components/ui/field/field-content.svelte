<script lang="ts">
<<<<<<< HEAD
import { cn, type WithElementRef } from "$lib/utils.js";
import type { HTMLAttributes } from "svelte/elements";

let {
	ref = $bindable(null),
	class: className,
	children,
	...restProps
}: WithElementRef<HTMLAttributes<HTMLDivElement>> = $props();
=======
	import { cn, type WithElementRef } from "$lib/utils.js";
	import type { HTMLAttributes } from "svelte/elements";

	let {
		ref = $bindable(null),
		class: className,
		children,
		...restProps
	}: WithElementRef<HTMLAttributes<HTMLDivElement>> = $props();
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
</script>

<div
	bind:this={ref}
	data-slot="field-content"
	class={cn("group/field-content flex flex-1 flex-col gap-1.5 leading-snug", className)}
	{...restProps}
>
	{@render children?.()}
</div>
