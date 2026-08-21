<script lang="ts">
import type { CalendarDate } from "@internationalized/date";
import { Label } from "$lib/components/ui/label";
import * as Popover from "$lib/components/ui/popover";
import { Button } from "$lib/components/ui/button";
import { Calendar } from "$lib/components/ui/calendar";
import { Input } from "$lib/components/ui/input";
import { getLocalTimeZone } from "@internationalized/date";
import { ChevronDownIcon } from "@lucide/svelte";
import { onMount } from "svelte";

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

let open = $state(false);
let hydrated = $state(false);

onMount(() => {
	hydrated = true;
});

function handleDateChange(newDate: CalendarDate | undefined) {
	date = newDate;
	onDateChange?.(newDate);
}
</script>

<div
	class="grid gap-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end"
	data-testid="{id}-date-time-picker"
	data-hydrated={hydrated}
>
	<div class="flex flex-col gap-3">
		<Label for="{id}-date">Date</Label>
		<Popover.Root bind:open>
			<Popover.Trigger>
				{#snippet child({ props })}
					<Button
						variant="outline"
						class="w-full justify-between font-normal"
						{...props}
						type="button"
						id="{id}-date"
						{disabled}
					>
						{date
							? date.toDate(getLocalTimeZone()).toLocaleDateString()
							: "Select date"}
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
	<div class="grid grid-cols-2 gap-3">
		<div class="flex flex-col gap-3">
			<Label for="{id}-time-from">From</Label>
			<Input
				type="time"
				id="{id}-time-from"
				step="1"
				bind:value={startTime}
				{disabled}
				onchange={(e: Event) => {
					onStartTimeChange?.((e.currentTarget as HTMLInputElement).value);
				}}
				class="h-11 bg-background appearance-none [&::-webkit-calendar-picker-indicator]:hidden [&::-webkit-calendar-picker-indicator]:appearance-none"
			/>
		</div>
		<div class="flex flex-col gap-3">
			<Label for="{id}-time-to">To</Label>
			<Input
				type="time"
				id="{id}-time-to"
				step="1"
				bind:value={endTime}
				{disabled}
				onchange={(e: Event) => {
					onEndTimeChange?.((e.currentTarget as HTMLInputElement).value);
				}}
				class="h-11 bg-background appearance-none [&::-webkit-calendar-picker-indicator]:hidden [&::-webkit-calendar-picker-indicator]:appearance-none"
			/>
		</div>
	</div>
</div>
