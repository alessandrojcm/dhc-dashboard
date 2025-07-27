<script lang="ts">
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import dayjs from 'dayjs';

	let { open = $bindable(), onConfirm, isPending }: {
		open: boolean;
		onConfirm: ({ pauseUntil }: { pauseUntil: string }) => void;
		isPending: boolean
	} = $props();

	let pauseUntil = $state('');

	const minDate = $derived(dayjs().add(1, 'day').format('YYYY-MM-DD'));
	const maxDate = $derived(dayjs().add(6, 'months').format('YYYY-MM-DD'));

	function handleConfirm(event: Event) {
		console.log('handleConfirm called, event:', event);
		event.preventDefault();
		event.stopPropagation();
		if (!pauseUntil) {
			return;
		}
		onConfirm({ pauseUntil });
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
			<Input
				id="pauseUntil"
				type="date"
				bind:value={pauseUntil}
				min={minDate}
				max={maxDate}
				required
			/>
		</div>

		<Dialog.Footer>
			<Button type="button" variant="outline" onclick={() => open = false}>Cancel</Button>
			<Button
				type="button"
				onclick={handleConfirm}
				disabled={!pauseUntil || isPending}
			>
				{isPending ? 'Pausing...' : 'Pause Subscription'}
			</Button>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
