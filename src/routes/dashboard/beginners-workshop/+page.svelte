<script lang="ts">
	import WaitlistTable from './waitlist-table.svelte';
	import Analytics from './workshop-analytics.svelte';
	import { Root, List, Trigger, Content } from '$lib/components/ui/tabs/index.js';
	import { Lock, LockOpen } from 'lucide-svelte';
	import * as AlertDialog from '$lib/components/ui/alert-dialog/index.js';
	import { Button } from '$lib/components/ui/button';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { createMutation, createQuery } from '@tanstack/svelte-query';
	import { goto, invalidate } from '$app/navigation';
	import { toast } from 'svelte-sonner';
	import { page } from '$app/state';
	import * as Select from '$lib/components/ui/select/index.js';
	import { PlusCircle } from 'lucide-svelte';
	import type { PageData } from './$types';
	import WorkshopsTable from './workshops-table.svelte';
	import * as Dialog from '$lib/components/ui/dialog/index.js';
	import { Input } from '$lib/components/ui/input';
	import DatePicker from '$lib/components/ui/date-picker.svelte';
	import Textarea from '$lib/components/ui/textarea/textarea.svelte';
	import type { DateValue } from '@internationalized/date';
	import type { SupabaseClient } from '@supabase/supabase-js';
	import { fromDate, getLocalTimeZone } from '@internationalized/date';

	let { data }: { data: PageData } = $props();
	const supabase = data.supabase;
	let dialogOpen = $state(false);
	let value = $derived(page.url.searchParams.get('tab') || 'dashboard');
	let createDialogOpen = $state(false);
	let isSubmitting = $state(false);
	let errorMsg = $state('');

	// Workshop form state
	let form = $state({
		workshop_date: '',
		location: '',
		coach_id: '',
		capacity: 16,
		notes_md: ''
	});
	let dateValue: DateValue | null = $state(null);

	type CoachProfile = {
		id: string;
		first_name: string;
		last_name: string;
	};

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

	function onTabChange(value: string) {
		const newParams = new URLSearchParams(page.url.searchParams);
		newParams.set('tab', value);
		goto(`/dashboard/beginners-workshop?${newParams.toString()}`);
	}
	let views = [
		{
			id: 'dashboard',
			label: 'Dashboard'
		},
		{
			id: 'waitlist',
			label: 'Waitlist'
		}
	];
	let viewLabel = $derived(views.find((view) => view.id === value)?.label || 'Dashboard');

	async function fetchCoachesFromApi() {
		const res = await fetch('/api/coaches');
		if (!res.ok) throw new Error('Failed to fetch coaches');
		return await res.json();
	}

	const coachesQuery = createQuery(() => ({
		queryKey: ['coaches'],
		queryFn: fetchCoachesFromApi
	}));

	function handleDateChange(date: Date) {
		if (!date) return;
		dateValue = fromDate(date, getLocalTimeZone());
		form.workshop_date = date.toISOString();
	}

	async function handleCreateWorkshop(e: Event) {
		e.preventDefault();
		isSubmitting = true;
		errorMsg = '';
		try {
			const res = await fetch('/api/workshops', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					workshop_date: form.workshop_date,
					location: form.location,
					coach_id: form.coach_id,
					capacity: Number(form.capacity),
					notes_md: form.notes_md
				})
			});
			if (!res.ok) {
				let errMsg = 'Failed to create workshop';
				try {
					const err = await res.json();
					if (err && typeof err === 'object' && 'error' in err && typeof err.error === 'string') errMsg = err.error;
				} catch {}
				throw new Error(errMsg);
			}
			createDialogOpen = false;
			// Reset form
			form = {
				workshop_date: '',
				location: '',
				coach_id: '',
				capacity: 16,
				notes_md: ''
			};
			dateValue = null;
			// Refresh workshops list
			invalidate('workshops');
			toast.success('Workshop created');
		} catch (error: unknown) {
			errorMsg = error instanceof Error ? error.message : String(error);
			toast.error(errorMsg);
		} finally {
			isSubmitting = false;
		}
	}
</script>

{#snippet waitlistToggleDialog()}
	{#if data.canToggleWaitlist}
		{#await data.isWaitlistOpen then isOpen}
			<AlertDialog.Root bind:open={dialogOpen}>
				<AlertDialog.Trigger class="fixed right-4 top-4">
					<Button variant="outline" onclick={() => (dialogOpen = true)}>
						{#if isOpen}
							<LockOpen class="w-4 h-4" />
							<p class="hidden md:block">Close Waitlist</p>
						{:else}
							<Lock class="w-4 h-4" />
							<p class="hidden md:block">Open Waitlist</p>
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
						<AlertDialog.Cancel onclick={() => (dialogOpen = false)}>Cancel</AlertDialog.Cancel>
						<AlertDialog.Action onclick={() => toggleWaitlistMutation.mutate()} data-testid="action"
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
	{/if}
{/snippet}
<div class="relative md:ml-2 md:pl-2">
	{@render waitlistToggleDialog()}
	<!-- Analytics/graphs section -->
	<div class="mb-8">
		<div class="mb-4">
			<Analytics {supabase} />
		</div>
	</div>

	<Root {value} class="p-2 min-h-96 mr-2" onValueChange={onTabChange}>
		<div class="inline-flex w-full mb-4">
			<Select.Root {value} type="single" onValueChange={onTabChange}>
				<Select.Trigger class="md:hidden flex w-fit" size="sm" id="view-selector">
					{viewLabel}
				</Select.Trigger>
				<Select.Content>
					{#each views as view (view.id)}
						<Select.Item value={view.id}>{view.label}</Select.Item>
					{/each}
				</Select.Content>
			</Select.Root>
			<List class="md:flex hidden">
				<Trigger value="dashboard">Workshops</Trigger>
				<Trigger value="waitlist">Waitlist</Trigger>
			</List>
		</div>

		<Content value="dashboard">
			<h2 class="prose prose-h2 text-lg mb-2">Workshop list</h2>
			<div class="flex items-center justify-between mb-4">
				<div class="flex items-center space-x-2">
					<Dialog.Root bind:open={createDialogOpen}>
						<Dialog.Trigger>
							<Button type="button" on:click={() => (createDialogOpen = true)}>
								<PlusCircle class="mr-2 h-4 w-4" />
								Create Workshop
							</Button>
						</Dialog.Trigger>
						<Dialog.Content class="sm:max-w-[500px]">
							<Dialog.Header>
								<Dialog.Title>New Workshop</Dialog.Title>
								<Dialog.Description>
									Fill in the details to create a new workshop in draft state.
								</Dialog.Description>
							</Dialog.Header>
							<form onsubmit={handleCreateWorkshop} class="space-y-4 mt-2">
								<div>
									<label class="block text-sm font-medium mb-1" for="workshop_date">Date</label>
									<DatePicker
										id="workshop_date"
										name="workshop_date"
										value={dateValue ?? fromDate(new Date(), getLocalTimeZone())}
										onDateChange={handleDateChange}
										data-fs-error=""
										aria-describedby=""
										aria-invalid={undefined}
										aria-required={undefined}
										data-fs-control=""
									/>
								</div>
								<div>
									<label class="block text-sm font-medium mb-1" for="location">Location</label>
									<Input id="location" bind:value={form.location} required />
								</div>
								<div>
									<label class="block text-sm font-medium mb-1" for="coach_id">Coach</label>
									<Select.Root
										type="single"
										name="coach_id"
										bind:value={form.coach_id}
									>
										<Select.Trigger class="w-full">
											{#if coachesQuery.isLoading}
												Loading...
											{:else if coachesQuery.isError}
												Error loading coaches
											{:else if form.coach_id}
												{#each Array.isArray(coachesQuery.data) ? coachesQuery.data : [] as CoachProfile[] as coach (coach.id)}
													{#if coach.id === form.coach_id}
														{coach.first_name} {coach.last_name}
													{/if}
												{/each}
											{:else}
												Select coach
											{/if}
										</Select.Trigger>
										<Select.Content>
											{#each Array.isArray(coachesQuery.data) ? coachesQuery.data : [] as CoachProfile[] as coach (coach.id)}
												<Select.Item value={coach.id} label={`${coach.first_name} ${coach.last_name}`}>
													{coach.first_name} {coach.last_name}
												</Select.Item>
											{/each}
										</Select.Content>
									</Select.Root>
								</div>
								<div>
									<label class="block text-sm font-medium mb-1" for="capacity">Capacity</label>
									<Input id="capacity" type="number" min="1" bind:value={form.capacity} required />
								</div>
								<div>
									<label class="block text-sm font-medium mb-1" for="notes_md">Notes</label>
									<Textarea id="notes_md" bind:value={form.notes_md} rows={3} />
								</div>
								{#if errorMsg}
									<div class="text-red-600 text-sm">{errorMsg}</div>
								{/if}
								<Dialog.Footer>
									<Button type="submit" disabled={isSubmitting}>
										{#if isSubmitting}
											<LoaderCircle class="animate-spin inline-block w-4 h-4 mr-2" />
											Creating...
										{:else}
											Create
										{/if}
									</Button>
								</Dialog.Footer>
							</form>
						</Dialog.Content>
					</Dialog.Root>
				</div>
			</div>
			<WorkshopsTable workshops={data.workshops} />
		</Content>
		<Content value="waitlist">
			<h2 class="prose prose-h2 text-lg mb-2">Waitlist</h2>
			<WaitlistTable {supabase} />
		</Content>
	</Root>
</div>
