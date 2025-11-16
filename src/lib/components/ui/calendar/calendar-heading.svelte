<script lang="ts">
import type { Calendar as CalendarPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: CalendarPrimitive.HeadingProps = $props();
</script>

<CalendarPrimitive.Heading
	bind:ref
	class={cn("px-(--cell-size) text-sm font-medium", className)}
	{...restProps}
/>
