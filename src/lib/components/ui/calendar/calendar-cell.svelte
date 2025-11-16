<script lang="ts">
import type { Calendar as CalendarPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: CalendarPrimitive.CellProps = $props();
</script>

<CalendarPrimitive.Cell
	bind:ref
	class={cn(
		"size-(--cell-size) relative p-0 text-center text-sm focus-within:z-20 [&:first-child[data-selected]_[data-bits-day]]:rounded-l-md [&:last-child[data-selected]_[data-bits-day]]:rounded-r-md",
		className
	)}
	{...restProps}
/>
