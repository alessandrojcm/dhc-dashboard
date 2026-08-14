<script lang="ts">
import CalendarIcon from "@lucide/svelte/icons/calendar";
import {
	type DateValue,
	DateFormatter,
	getLocalTimeZone,
} from "@internationalized/date";
import { cn } from "$lib/utils.js";
import { Button } from "$lib/components/ui/button/index.js";
import { Calendar } from "$lib/components/ui/calendar";
import * as Popover from "$lib/components/ui/popover/index.js";

type Props = {
	value: DateValue | undefined;
	onDateChange: (date: Date) => void;
	minValue?: DateValue;
	maxValue?: DateValue;
	name?: string;
	id?: string;
	label?: string;
	type?: string;
};

const df = new DateFormatter("en-US", {
	dateStyle: "long",
});

let { value, onDateChange, minValue, maxValue, name, id, label }: Props =
	$props();
let open = $state(false);

// DatePicker is used for calendar dates (birthdays, resume dates), not instants.
const formValue = $derived(value?.toString() ?? "");
</script>

<div>
	<Popover.Root bind:open>
		<Popover.Trigger>
			{#snippet child({ props })}
				<Button
					variant="outline"
					class={cn(
						"w-full justify-start text-left font-normal",
						!value && "text-muted-foreground",
					)}
					{...props}
					type="button"
					{id}
					aria-label={label}
				>
					<CalendarIcon class="mr-2 size-4" />
					{value
						? df.format(value.toDate(getLocalTimeZone()))
						: "Select a date"}
				</Button>
			{/snippet}
		</Popover.Trigger>
		<Popover.Content class="w-auto p-0">
			<Calendar
				bind:value
				type="single"
				initialFocus
				captionLayout="dropdown"
				{minValue}
				{maxValue}
				onValueChange={(date: DateValue | undefined) => {
					if (date) {
						onDateChange(date.toDate(getLocalTimeZone()));
					}
					open = false;
				}}
			/>
		</Popover.Content>
	</Popover.Root>
	<input type="hidden" {name} value={formValue} />
</div>
