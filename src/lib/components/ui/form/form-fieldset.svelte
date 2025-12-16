<script lang="ts">
	import { cn } from '$lib/utils.js';
	import type { HTMLFieldsetAttributes } from 'svelte/elements';

	interface Props extends HTMLFieldsetAttributes {
		ref?: HTMLFieldSetElement | null;
	}

	let {
		ref = $bindable(null),
		class: className,
		children,
		...restProps
	}: Props = $props();
</script>

<fieldset
	bind:this={ref}
	class={cn('space-y-2', className)}
	{...restProps}
>
	{@render children?.()}
</fieldset>
