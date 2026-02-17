<script lang="ts">
	import { cn } from '$lib/utils.js';
	import type { HTMLAttributes } from 'svelte/elements';

	interface Issue {
		message: string;
	}

	interface Props extends HTMLAttributes<HTMLDivElement> {
		ref?: HTMLDivElement | null;
		/**
		 * Array of validation issues to display
		 */
		issues?: Issue[];
		/**
		 * Additional classes for each error message
		 */
		errorClasses?: string | undefined | null;
	}

	let {
		ref = $bindable(null),
		class: className,
		issues = [],
		errorClasses,
		...restProps
	}: Props = $props();
</script>

{#if issues.length > 0}
	<div
		bind:this={ref}
		class={cn('text-destructive text-sm font-medium', className)}
		{...restProps}
	>
		{#each issues as issue (issue.message)}
			<div class={cn(errorClasses)}>{issue.message}</div>
		{/each}
	</div>
{/if}
