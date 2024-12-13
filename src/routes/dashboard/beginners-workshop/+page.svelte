<script lang="ts">
	import WaitlistTable from './waitlist-table.svelte';
	import Analytics from './workshop-analytics.svelte';
	import * as Tabs from '$lib/components/ui/tabs/index.js';
	import { Lock, LockOpen } from 'lucide-svelte';
	import * as AlertDialog from '$lib/components/ui/alert-dialog/index.js';
	import Button from '$lib/components/ui/button/button.svelte';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { createMutation } from '@tanstack/svelte-query';
	import { invalidate } from '$app/navigation';
	import { toast } from 'svelte-sonner';

	const { data } = $props();
	const supabase = data.supabase;
	let value = $state('dashboard');

	const toggleWaitlistMutation = createMutation(() => ({
		mutationFn: async () => {
			return supabase
				.from('settings')
				.update({ value: (await data.isWaitlistOpen) === false ? 'true' : 'false' })
				.eq('key', 'waitlist_open')
				.select();
		},
		onSuccess: () => {
			invalidate('wailist:status');
			toast.success('Waitlist status updated', { position: 'top-center' });
		},
		onError: () => {
			toast.error('Error updating waitlist status', { position: 'top-center' });
		}
	}));
</script>

{#snippet waitlistToggleDialog()}
	{#await data.isWaitlistOpen then isOpen}
		<AlertDialog.Root>
			<AlertDialog.Trigger class="flex items-center gap-1 ml-auto">
				{#if isOpen}
					<LockOpen class="w-4 h-4" />
					Close Waitlist
				{:else}
					<Lock class="w-4 h-4" />
					Open Waitlist
				{/if}
			</AlertDialog.Trigger>
			<AlertDialog.Content>
				<AlertDialog.Header>
					<AlertDialog.Title>{isOpen ? 'Close' : 'Open'} waitlist</AlertDialog.Title>
					<AlertDialog.Description>
						Are you sure you want to {isOpen ? 'close' : 'open'} the waitlist? This action will affect
						new registrations.
					</AlertDialog.Description>
				</AlertDialog.Header>
				<AlertDialog.Footer>
					<AlertDialog.Cancel>Cancel</AlertDialog.Cancel>
					<AlertDialog.Action onclick={() => toggleWaitlistMutation.mutate()}
						>{isOpen ? 'Close' : 'Open'}</AlertDialog.Action
					>
				</AlertDialog.Footer>
			</AlertDialog.Content>
		</AlertDialog.Root>
	{:catch}
		<Button disabled class="ml-auto">
			<LoaderCircle class="w-4 h-4 mr-1" />
			Loading...
		</Button>
	{/await}
{/snippet}

<Tabs.Root bind:value class="p-2 min-h-96 mr-2">
	<div class="inline-flex w-full">
		<Tabs.List>
			<Tabs.Trigger value="dashboard">Dashboard</Tabs.Trigger>
			<Tabs.Trigger value="waitlist">Waitlist</Tabs.Trigger>
		</Tabs.List>
		{@render waitlistToggleDialog()}
	</div>

	<Tabs.Content value="dashboard">
		<Analytics {supabase} />
	</Tabs.Content>
	<Tabs.Content value="waitlist">
		<WaitlistTable {supabase} />
	</Tabs.Content>
</Tabs.Root>
