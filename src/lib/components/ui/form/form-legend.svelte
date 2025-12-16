<script lang="ts">
	import { cn } from '$lib/utils.js';
	import type { HTMLAttributes } from 'svelte/elements';

	interface Props extends HTMLAttributes<HTMLLegendElement> {
		ref?: HTMLLegendElement | null;
	}

	let {
		ref = $bindable(null),
		class: className,
		children,
		...restProps
	}: Props = $props();
</script>

<legend
	bind:this={ref}
	class={cn('text-sm font-medium leading-none', className)}
	{...restProps}
>
	{@render children?.()}
</legend>
