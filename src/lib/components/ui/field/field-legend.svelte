<script lang="ts">
<<<<<<< HEAD
import { cn, type WithElementRef } from "$lib/utils.js";
import type { HTMLAttributes } from "svelte/elements";

let {
	ref = $bindable(null),
	class: className,
	variant = "legend",
	children,
	...restProps
}: WithElementRef<HTMLAttributes<HTMLLegendElement>> & {
	variant?: "legend" | "label";
} = $props();
=======
	import { cn, type WithElementRef } from "$lib/utils.js";
	import type { HTMLAttributes } from "svelte/elements";

	let {
		ref = $bindable(null),
		class: className,
		variant = "legend",
		children,
		...restProps
	}: WithElementRef<HTMLAttributes<HTMLLegendElement>> & {
		variant?: "legend" | "label";
	} = $props();
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
</script>

<legend
	bind:this={ref}
	data-slot="field-legend"
	data-variant={variant}
	class={cn(
		"mb-3 font-medium",
		"data-[variant=legend]:text-base",
		"data-[variant=label]:text-sm",
		className
	)}
	{...restProps}
>
	{@render children?.()}
</legend>
