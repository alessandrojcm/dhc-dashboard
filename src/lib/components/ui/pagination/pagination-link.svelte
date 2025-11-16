<script lang="ts">
import type { Pagination as PaginationPrimitive } from "bits-ui";
import type { Props } from "$lib/components/ui/button/index.js";

const {
	ref = $bindable(null),
	class: className,
	size = "icon",
	isActive,
	page,
	children,
	...restProps
}: PaginationPrimitive.PageProps &
	Props & {
		isActive: boolean;
	} = $props();
</script>

{#snippet Fallback()}
	{page.value}
{/snippet}

<PaginationPrimitive.Page
	bind:ref
	{page}
	aria-current={isActive ? "page" : undefined}
	data-slot="pagination-link"
	data-active={isActive}
	class={cn(
		buttonVariants({
			variant: isActive ? "outline" : "ghost",
			size,
		}),
		className
	)}
	children={children || Fallback}
	{...restProps}
/>
