<script lang="ts">
import {
	type DateValue,
	fromDate,
	getLocalTimeZone,
} from "@internationalized/date";
import dayjs from "dayjs";

const {
	open = $bindable(),
	onConfirm,
	isPending,
	extend = false,
	pausedUntil,
}: {
	open: boolean;
	onConfirm: ({ pauseUntil }: { pauseUntil: string }) => void;
	isPending: boolean;
	extend?: boolean;
	pausedUntil?: dayjs.Dayjs;
} = $props();

const minDate = $derived(
	fromDate((pausedUntil ?? dayjs().add(1, "day")).toDate(), getLocalTimeZone()),
);
const _maxDate = $derived(
	fromDate(dayjs().add(6, "months").toDate(), getLocalTimeZone()),
);
let selectedDate = $state<DateValue | undefined>();

$effect(() => {
	selectedDate = minDate;
});

function _handleConfirm(event: Event) {
	event.preventDefault();
	event.stopPropagation();
	if (!selectedDate) {
		return;
	}
	onConfirm({
		pauseUntil: selectedDate.toDate(getLocalTimeZone()).toISOString(),
	});
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
				name="pauseUntil"
				id="pauseUntil"
				data-fs-error={undefined}
				aria-describedby={undefined}
				aria-invalid={undefined}
				aria-required={undefined}
				data-fs-control="pauseUntil"
			/>
		</div>

		<Dialog.Footer>
			<Button type="button" variant="outline" onclick={() => (open = false)}>Cancel</Button>
			<Button type="button" onclick={handleConfirm} disabled={!selectedDate || isPending}>
				{#if extend}
					{isPending ? 'Extending...' : 'Extend subscription pause'}
				{:else}
					{isPending ? 'Pausing...' : 'Pause subscription'}
				{/if}
			</Button>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
