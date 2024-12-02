<script lang="ts">
	import type { WithoutChild } from 'bits-ui';
	import * as FormPrimitive from 'formsnap';
	import { Label } from '$lib/components/ui/label/index.js';
	import { cn } from '$lib/utils.js';

	let {
		ref = $bindable(null),
		children,
		class: className,
		required = false,
		...restProps
	}: WithoutChild<FormPrimitive.LabelProps> & { required?: boolean } = $props();
</script>

<FormPrimitive.Label {...restProps} bind:ref aria-required={required.toString()}>
	{#snippet child({ props })}
		<Label {...props} class={cn('data-[fs-error]:text-destructive', className)}>
			{@render children?.()}
		</Label>
		{#if required}
			<span class="text-red-500">*</span>
		{/if}
	{/snippet}
</FormPrimitive.Label>
