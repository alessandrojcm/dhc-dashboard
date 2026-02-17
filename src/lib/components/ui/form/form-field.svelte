<script lang="ts" generics="T extends RemoteFormFieldValue = RemoteFormFieldValue">
import { cn, type WithElementRef, type WithoutChildren } from "$lib/utils.js";
import type { HTMLAttributes } from "svelte/elements";
import type { Snippet } from "svelte";
import type { RemoteFormField, RemoteFormFieldValue } from "@sveltejs/kit";

interface Props
	extends WithoutChildren<WithElementRef<HTMLAttributes<HTMLDivElement>>> {
	/**
	 * The field object from Remote Functions form
	 * e.g., myForm.fields.email
	 */
	field: RemoteFormField<T>;
	/**
	 * Children snippet - receives the field for custom rendering
	 */
	children?: Snippet<[RemoteFormField<T>]>;
}

let {
	ref = $bindable(null),
	class: className,
	field,
	children: childrenProp,
	...restProps
}: Props = $props();
</script>

<div 
	bind:this={ref} 
	data-slot="form-item" 
	class={cn('space-y-2', className)} 
	{...restProps}
>
	{#if childrenProp}
		{@render childrenProp(field)}
	{/if}
	
	{#each field.issues() as issue}
		<p class="text-destructive text-sm font-medium">{issue.message}</p>
	{/each}
</div>
