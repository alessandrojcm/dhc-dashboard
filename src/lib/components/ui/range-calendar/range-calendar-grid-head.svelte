<script lang="ts">
import type { RangeCalendar as RangeCalendarPrimitive } from "bits-ui";

const {
	ref = $bindable(null),
	class: className,
	...restProps
}: RangeCalendarPrimitive.GridHeadProps = $props();
</script>

<RangeCalendarPrimitive.GridHead bind:ref class={cn(className)} {...restProps} />
