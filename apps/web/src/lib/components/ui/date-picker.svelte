<script lang="ts">
import CalendarIcon from "@lucide/svelte/icons/calendar";
import {
	type DateValue,
	DateFormatter,
	getLocalTimeZone,
	toCalendarDate,
} from "@internationalized/date";
import { cn } from "#lib/utils.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Calendar } from "#lib/components/ui/calendar/index.js";
import * as Popover from "#lib/components/ui/popover/index.js";

type Props = {
	value: DateValue | undefined;
	onDateChange?: (date: Date) => void;
	onValueChange?: (value: DateValue | undefined) => void;
	minValue?: DateValue;
	maxValue?: DateValue;
	name?: string;
	id?: string;
	label?: string;
	dateStyle?: "long" | "medium" | "short";
	type?: string;
	/** Phoenix's field-scoped refusal for this date, so the trigger reads invalid. */
	ariaInvalid?: boolean;
	ariaDescribedby?: string;
	class?: string;
};

let {
	value,
	onDateChange,
	onValueChange,
	minValue,
	maxValue,
	name,
	id,
	label,
	dateStyle = "long",
	ariaInvalid = false,
	ariaDescribedby,
	class: className,
}: Props = $props();
let open = $state(false);
const df = $derived(new DateFormatter("en-US", { dateStyle }));

// DatePicker is used for calendar dates (birthdays, resume dates), not instants.
const formValue = $derived(value ? toCalendarDate(value).toString() : "");
</script>

<div class="w-full min-w-0">
	<Popover.Root bind:open>
		<Popover.Trigger>
			{#snippet child({ props })}
				<Button
					{...props}
					variant="outline"
					class={cn(
						"min-h-11 w-full min-w-0 justify-start text-left font-normal",
						!value && "text-muted-foreground",
						className,
					)}
					type="button"
					{id}
					aria-label={label}
					aria-invalid={ariaInvalid}
					aria-describedby={ariaDescribedby}
				>
					<CalendarIcon class="size-4 shrink-0" />
					<span class="truncate"
						>{value
							? df.format(value.toDate(getLocalTimeZone()))
							: "Select a date"}</span
					>
				</Button>
			{/snippet}
		</Popover.Trigger>
		<Popover.Content class="w-auto p-0">
			<Calendar
				bind:value
				type="single"
				preventDeselect
				initialFocus
				captionLayout="dropdown"
				{minValue}
				{maxValue}
				onValueChange={(date: DateValue | undefined) => {
					if (date) {
						onDateChange?.(date.toDate(getLocalTimeZone()));
					}
					open = false;
					onValueChange?.(date);
				}}
			/>
		</Popover.Content>
	</Popover.Root>
	<input type="hidden" {name} value={formValue} />
</div>
