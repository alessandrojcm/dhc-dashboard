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
	import { superForm, defaults, setMessage } from 'sveltekit-superforms/client';
	import { valibotClient, valibot } from 'sveltekit-superforms/adapters';
	import { workshopCreateSchema } from '$lib/schemas/workshopCreate';
	import * as Form from '$lib/components/ui/form/index.js';
	import dayjs from 'dayjs';

	let { data }: { data: PageData } = $props();
	const supabase = data.supabase;
	let dialogOpen = $state(false);
	let value = $derived(page.url.searchParams.get('tab') || 'dashboard');
	let createDialogOpen = $state(false);

	// Setup superForm
	const form = superForm(defaults(valibot(workshopCreateSchema)), {
		validators: valibotClient(workshopCreateSchema),
		applyAction: false,
		resetForm: true,
		validationMethod: 'oninput',
		SPA: true,
		async onUpdate({ form }) {
			if (!form.valid) return;
			try {
				const res = await fetch('/api/workshops', {
					method: 'POST',
					headers: { 'Content-Type': 'application/json' },
					body: JSON.stringify(form.data)
				});
				if (!res.ok) {
					let errMsg = 'Failed to create workshop';
					try {
						const err = await res.json();
						if (err && typeof err === 'object' && 'error' in err && typeof err.error === 'string') errMsg = err.error;
					} catch {}
					setMessage(form, { failure: errMsg });
					return;
				}
				setMessage(form, { success: 'Workshop created!' });
				await invalidate('/dashboard/beginners-workshop');
				reset();
				createDialogOpen = false;
			} catch (error: unknown) {
				setMessage(form, { failure: error instanceof Error ? error.message : String(error) });
			}
		}
	});
	const { form: formData, message, reset, validateForm, submitting, enhance } = form;

	// Date handling for DatePicker
	const dateValue = $derived.by(() => {
		if (!$formData.workshop_date || !dayjs($formData.workshop_date).isValid()) return null;
		return fromDate(dayjs($formData.workshop_date).toDate(), getLocalTimeZone());
	});

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
							<form class="space-y-4 mt-2" use:enhance>
								<Form.Field {form} name="workshop_date">
									<Form.Control>
										{#snippet children({ props })}
											<Form.Label required>Date</Form.Label>
											<DatePicker
												{...props}
												value={dateValue}
												onDateChange={date => $formData.workshop_date = date.toISOString()}
											/>
										{/snippet}
									</Form.Control>
									<Form.FieldErrors />
								</Form.Field>
								<Form.Field {form} name="location">
									<Form.Control>
										{#snippet children({ props })}
											<Form.Label required>Location</Form.Label>
											<Input {...props} bind:value={$formData.location} />
										{/snippet}
									</Form.Control>
									<Form.FieldErrors />
								</Form.Field>
								<Form.Field {form} name="coach_id">
									<Form.Control>
										{#snippet children({ props })}
											<Form.Label required>Coach</Form.Label>
											<Select.Root
												type="single"
												name="coach_id"
												bind:value={$formData.coach_id}
											>
												<Select.Trigger class="w-full">
													{#if coachesQuery.isLoading}
														Loading...
													{:else if coachesQuery.isError}
														Error loading coaches
													{:else if $formData.coach_id}
														{#each Array.isArray(coachesQuery.data) ? coachesQuery.data : [] as coach (coach.id)}
															{#if coach.id === $formData.coach_id}
																{coach.first_name} {coach.last_name}
															{/if}
														{/each}
													{:else}
														Select coach
													{/if}
												</Select.Trigger>
												<Select.Content>
													{#each Array.isArray(coachesQuery.data) ? coachesQuery.data : [] as coach (coach.id)}
														<Select.Item value={coach.id} label={`${coach.first_name} ${coach.last_name}`}>
															{coach.first_name} {coach.last_name}
														</Select.Item>
													{/each}
												</Select.Content>
											</Select.Root>
										{/snippet}
									</Form.Control>
									<Form.FieldErrors />
								</Form.Field>
								<Form.Field {form} name="capacity">
									<Form.Control>
										{#snippet children({ props })}
											<Form.Label required>Capacity</Form.Label>
											<Input {...props} type="number" min="1" bind:value={$formData.capacity} />
										{/snippet}
									</Form.Control>
									<Form.FieldErrors />
								</Form.Field>
								<Form.Field {form} name="notes_md">
									<Form.Control>
										{#snippet children({ props })}
											<Form.Label>Notes</Form.Label>
											<Textarea {...props} bind:value={$formData.notes_md} rows={3} />
										{/snippet}
									</Form.Control>
									<Form.FieldErrors />
								</Form.Field>
								{#if $message?.error}
									<div class="text-red-600 text-sm">{$message.error}</div>
								{/if}
								<Dialog.Footer>
									<Button type="submit" disabled={$submitting}>
										{#if $submitting}
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
