<script lang="ts">
import type { CalendarDate } from "@internationalized/date";

interface Props {
	id: string;
	date?: CalendarDate;
	startTime?: string;
	endTime?: string;
	onDateChange?: (date: CalendarDate | undefined) => void;
	onStartTimeChange?: (time: string) => void;
	onEndTimeChange?: (time: string) => void;
	disabled?: boolean;
}

let {
	id,
	date = $bindable(),
	startTime = $bindable(),
	endTime = $bindable(),
	onDateChange,
	onStartTimeChange,
	onEndTimeChange,
	disabled,
}: Props = $props();

const _open = $state(false);

function _handleDateChange(newDate: CalendarDate | undefined) {
	date = newDate;
	onDateChange?.(newDate);
}

function _handleStartTimeChange(newTime: string) {
	startTime = newTime;
	onStartTimeChange?.(newTime);
}

function _handleEndTimeChange(newTime: string) {
	endTime = newTime;
	onEndTimeChange?.(newTime);
}
</script>

<div class="flex flex-col gap-6">
	<div class="flex flex-col gap-3">
		<Label for="{id}-date" class="px-1">Date</Label>
		<Popover.Root bind:open>
			<Popover.Trigger id="{id}-date">
				{#snippet child({ props })}
					<Button
						{disabled}
						{...props}
						variant="outline"
						class="w-full justify-between font-normal"
					>
						{date ? date.toDate(getLocalTimeZone()).toLocaleDateString() : 'Select date'}
						<ChevronDownIcon />
					</Button>
				{/snippet}
			</Popover.Trigger>
			<Popover.Content class="w-auto overflow-hidden p-0" align="start">
				<Calendar
					type="single"
					value={date}
					captionLayout="dropdown"
					{disabled}
					onValueChange={(newDate?: CalendarDate) => {
						handleDateChange(newDate);
						open = false;
					}}
				/>
			</Popover.Content>
		</Popover.Root>
	</div>
	<div class="flex gap-4">
		<div class="flex flex-col gap-3">
			<Label for="{id}-time-from" class="px-1">From</Label>
			<Input
				type="time"
				id="{id}-time-from"
				step="1"
				value={startTime || '10:30'}
				{disabled}
				oninput={(e: Event) => {
					handleStartTimeChange((e.currentTarget as HTMLInputElement).value);
				}}
				class="bg-background appearance-none [&::-webkit-calendar-picker-indicator]:hidden [&::-webkit-calendar-picker-indicator]:appearance-none"
			/>
		</div>
		<div class="flex flex-col gap-3">
			<Label for="{id}-time-to" class="px-1">To</Label>
			<Input
				type="time"
				id="{id}-time-to"
				step="1"
				value={endTime || '12:30'}
				{disabled}
				oninput={(e: Event) => {
					handleEndTimeChange((e.currentTarget as HTMLInputElement).value);
				}}
				class="bg-background appearance-none [&::-webkit-calendar-picker-indicator]:hidden [&::-webkit-calendar-picker-indicator]:appearance-none"
			/>
		</div>
	</div>
</div>
