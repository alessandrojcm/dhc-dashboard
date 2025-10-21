<script lang="ts">
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Label } from '$lib/components/ui/label';
	import DatePicker from '$lib/components/ui/date-picker.svelte';
	import dayjs from 'dayjs';
	import { type DateValue, fromDate, getLocalTimeZone } from '@internationalized/date';

	let { open = $bindable(), onConfirm, isPending, extend = false }: {
		open: boolean;
		onConfirm: ({ pauseUntil }: { pauseUntil: string }) => void;
		isPending: boolean;
		extend?: boolean;
	} = $props();

	const minDate = $derived(fromDate(dayjs().add(1, 'day').toDate(), getLocalTimeZone()));
	const maxDate = $derived(fromDate(dayjs().add(6, 'months').toDate(), getLocalTimeZone()));
	let selectedDate = $state<DateValue | undefined>(minDate);

	function handleConfirm(event: Event) {
		event.preventDefault();
		event.stopPropagation();
		if (!selectedDate) {
			return;
		}
		onConfirm({ pauseUntil: selectedDate.toDate(getLocalTimeZone()).toISOString() });
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content>
		<Dialog.Header>
			<Dialog.Title>Pause Subscription</Dialog.Title>
			<Dialog.Description>
				Choose when you'd like your subscription to resume. You can pause for up to 6 months.
			</Dialog.Description>
		</Dialog.Header>

		<div class="space-y-4">
			<Label for="pauseUntil">Resume Date</Label>
			<DatePicker
				value={selectedDate ?? fromDate(new Date(), getLocalTimeZone())}
			  minValue={minDate}
				maxValue={maxDate}
				onDateChange={(date) => {
					selectedDate = fromDate(date, getLocalTimeZone());
				}}
			/>
		</div>

		<Dialog.Footer>
			<Button type="button" variant="outline" onclick={() => open = false}>Cancel</Button>
			<Button
				type="button"
				onclick={handleConfirm}
				disabled={!selectedDate || isPending}
			>
				{isPending && !extend ? 'Pausing...' : 'Pause subscription'}
				{isPending && extend ? 'Extending...' : 'Extend subscription pause'}
			</Button>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
