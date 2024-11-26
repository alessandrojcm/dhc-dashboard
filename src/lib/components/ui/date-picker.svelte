<script lang="ts">
	import CalendarIcon from 'lucide-svelte/icons/calendar';
	import { type DateValue, DateFormatter, getLocalTimeZone } from '@internationalized/date';
	import { cn } from '$lib/utils.js';
	import { Button } from '$lib/components/ui/button/index.js';
	import { Calendar } from '$lib/components/ui/calendar/index.js';
	import * as Popover from '$lib/components/ui/popover/index.js';

	type Props = {
		value: DateValue;
		onDateChange: (date: Date) => void;
		name: string;
		id: string;
		'data-fs-error': string | undefined;
		'aria-describedby': string | undefined;
		'aria-invalid': 'true' | undefined;
		'aria-required': 'true' | undefined;
		'data-fs-control': string;
	};

	const df = new DateFormatter('en-US', {
		dateStyle: 'long'
	});

	let { value, onDateChange, ...rest }: Props = $props();
	let open = $state(false);
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
			onValueChange={(date) => {
				date && onDateChange(date.toDate(getLocalTimeZone()));
				open = false;
			}}
		/>
	</Popover.Content>
</Popover.Root>
