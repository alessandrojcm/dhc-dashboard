<script lang="ts">
	import CalendarIcon from 'lucide-svelte/icons/calendar';
	import { type DateValue, DateFormatter, getLocalTimeZone } from '@internationalized/date';
	import { cn } from '$lib/utils.js';
	import { Button } from '$lib/components/ui/button/index.js';
	import { Calendar } from '$lib/components/ui/calendar';
	import * as Popover from '$lib/components/ui/popover/index.js';

	type Props = {
		value: DateValue | undefined;
		onDateChange: (date: Date) => void;
		minValue?: DateValue;
		maxValue?: DateValue;
		name?: string;
		id?: string;
	};

	const df = new DateFormatter('en-US', {
		dateStyle: 'long'
	});

	let { value, onDateChange, minValue, maxValue, name, id, ...rest }: Props = $props();
	let open = $state(false);

	// Derive the ISO string value for form submission
	const formValue = $derived(value ? value.toDate(getLocalTimeZone()).toISOString() : '');
</script>

<div>
	<Popover.Root bind:open>
		<Popover.Trigger {...rest}>
			{#snippet child({ props })}
				<Button
					variant="outline"
					class={cn('w-full justify-start text-left font-normal', !value && 'text-muted-foreground')}
					{...props}
					{id}
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
