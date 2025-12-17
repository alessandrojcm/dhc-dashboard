<script lang="ts">
<<<<<<< HEAD
import { Separator as SeparatorPrimitive } from "bits-ui";
import { cn } from "$lib/utils.js";

let {
	ref = $bindable(null),
	class: className,
	"data-slot": dataSlot = "separator",
	...restProps
}: SeparatorPrimitive.RootProps = $props();
=======
	import { Separator as SeparatorPrimitive } from "bits-ui";
	import { cn } from "$lib/utils.js";

	let {
		ref = $bindable(null),
		class: className,
		"data-slot": dataSlot = "separator",
		...restProps
	}: SeparatorPrimitive.RootProps = $props();
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
</script>

<SeparatorPrimitive.Root
	bind:ref
	data-slot={dataSlot}
	class={cn(
		"bg-border shrink-0 data-[orientation=horizontal]:h-px data-[orientation=horizontal]:w-full data-[orientation=vertical]:h-full data-[orientation=vertical]:w-px",
		className
	)}
	{...restProps}
/>
