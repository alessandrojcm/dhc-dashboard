<script lang="ts">
import { DateFormatter, type DateValue } from "@internationalized/date";

type Props = {
	value: DateValue | undefined;
	onDateChange: (date: Date) => void;
	minValue?: DateValue;
	maxValue?: DateValue;
	name: string;
	id: string;
	"data-fs-error": string | undefined;
	"aria-describedby": string | undefined;
	"aria-invalid": "true" | undefined;
	"aria-required": "true" | undefined;
	"data-fs-control": string;
};

const _df = new DateFormatter("en-US", {
	dateStyle: "long",
});

const { value, onDateChange, minValue, maxValue, ...rest }: Props = $props();
const _open = $state(false);
</script>

<Popover.Root bind:open>
	<Popover.Trigger {...rest}>
		{#snippet child({ props })}
			<Button
				variant="outline"
				class={cn('w-full justify-start text-left font-normal', !value && 'text-muted-foreground')}
				{...props}
			>
				<CalendarIcon class="mr-2 size-4" />
				{value ? df.format(value.toDate(getLocalTimeZone())) : 'Select a date'}
			</Button>
		{/snippet}
	</Popover.Trigger>
	<Popover.Content class="w-auto p-0">
		<Calendar
			bind:value
			type="single"
			initialFocus
			{minValue}
			{maxValue}
			onValueChange={(date: DateValue | undefined) => {
				date && onDateChange(date.toDate(getLocalTimeZone()));
				open = false;
			}}
		/>
	</Popover.Content>
</Popover.Root>
