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
	let dialogOpen = $state(false);

	const toggleWaitlistMutation = createMutation(() => ({
		mutationFn: async () => {
			const response = await fetch('/dashboard/beginners-workshop', {
				method: 'POST'
			});
			const result = await response.json();
			if (!result.success) {
				throw new Error(result.error || 'Failed to toggle waitlist');
			}
			return result;
		},
		onSuccess: () => {
			invalidate('wailist:status');
			toast.success('Waitlist status updated', { position: 'top-center' });
			dialogOpen = false;
		},
		onError: (error) => {
			toast.error(error.message || 'Error updating waitlist status', { position: 'top-center' });
			dialogOpen = false;
		}
	}));
</script>

{#snippet waitlistToggleDialog()}
	{#if data.canToggleWaitlist}
		{#await data.isWaitlistOpen then isOpen}
			<AlertDialog.Root bind:open={dialogOpen}>
				<AlertDialog.Trigger class="fixed right-4 top-4">
					<Button variant="outline" onclick={() => dialogOpen = true}>
						{#if isOpen}
							<LockOpen class="w-4 h-4" />
							Close Waitlist
						{:else}
							<Lock class="w-4 h-4" />
							Open Waitlist
						{/if}
					</Button>
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
						<AlertDialog.Cancel onclick={() => dialogOpen = false}>Cancel</AlertDialog.Cancel>
						<AlertDialog.Action onclick={() => toggleWaitlistMutation.mutate()}
							data-testid="action">{isOpen ? 'Close' : 'Open'}</AlertDialog.Action
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
	{/if}
{/snippet}
<div class="relative">
	{@render waitlistToggleDialog()}
	<Tabs.Root bind:value class="p-2 min-h-96 mr-2">
		<div class="inline-flex w-full">
			<Tabs.List>
				<Tabs.Trigger value="dashboard">Dashboard</Tabs.Trigger>
				<Tabs.Trigger value="waitlist">Waitlist</Tabs.Trigger>
			</Tabs.List>
		</div>

		<Tabs.Content value="dashboard">
			<Analytics {supabase} />
		</Tabs.Content>
		<Tabs.Content value="waitlist">
			<WaitlistTable {supabase} />
		</Tabs.Content>
	</Tabs.Root>
</div>
