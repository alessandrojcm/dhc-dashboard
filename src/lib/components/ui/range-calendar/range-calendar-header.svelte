<script lang="ts">
import type { RangeCalendar as RangeCalendarPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: RangeCalendarPrimitive.HeaderProps = $props();
</script>

<RangeCalendarPrimitive.Header
	bind:ref
	class={cn(
		"h-(--cell-size) flex w-full items-center justify-center gap-1.5 text-sm font-medium",
		className
	)}
	{...restProps}
/>
