<script lang="ts">
	import { goto } from '$app/navigation';
	import { Button } from '$lib/components/ui/button';
	import { Alert, AlertDescription } from '$lib/components/ui/alert';
	import WorkshopCalendar from '$lib/components/workshops/workshop-calendar.svelte';
	import { createQuery, createMutation, useQueryClient } from '@tanstack/svelte-query';
	import type { Workshop } from '$lib/types';

	// Improvement: add pagination by month
	let {
		data
	} = $props();
	const queryClient = useQueryClient();
	const supabase = data.supabase;
	const userId = data!.user!.id;


	const workshopsQuery = createQuery(() => ({
		queryKey: ['workshops'],
		refetchOnMount: true,
		queryFn: async ({ signal }) => {
			const { data, error } = await supabase
				.from('club_activities')
				.select(`
					*,
					interest_count:club_activity_interest_counts(interest_count),
					user_interest:club_activity_interest(user_id)
				`)
				.abortSignal(signal);

			if (error) throw error;
			return data;
		}
	}));

	// Mutations for workshop actions
	const deleteMutation = createMutation(() => ({
		mutationFn: async (workshopId: string) => {
			const response = await fetch(`/api/workshops/${workshopId}`, {
				method: 'DELETE'
			});
			if (!response.ok) throw new Error('Failed to delete workshop');
			return response.json();
		},
		onSuccess: () => {
			queryClient.invalidateQueries({ queryKey: ['workshops'] });
		}
	}));

	const publishMutation = createMutation(() => ({
		mutationFn: async (workshopId: string) => {
			const response = await fetch(`/api/workshops/${workshopId}/publish`, {
				method: 'POST'
			});
			if (!response.ok) throw new Error('Failed to publish workshop');
			return response.json();
		},
		onSuccess: () => {
			queryClient.invalidateQueries({ queryKey: ['workshops'] });
		}
	}));

	const cancelMutation = createMutation(() => ({
		mutationFn: async (workshopId: string) => {
			const response = await fetch(`/api/workshops/${workshopId}/cancel`, {
				method: 'POST'
			});
			if (!response.ok) throw new Error('Failed to cancel workshop');
			return response.json();
		},
		onSuccess: () => {
			queryClient.invalidateQueries({ queryKey: ['workshops'] });
		}
	}));

	function handleCreate() {
		goto('/dashboard/workshops/create');
	}

	function handleEdit(workshop: Workshop) {
		goto(`/dashboard/workshops/${workshop.id}/edit`);
	}

	async function handleDelete(workshop: Workshop) {
		if (!confirm(`Are you sure you want to delete "${workshop.title}"?`)) return;
		deleteMutation.mutate(workshop.id);
	}

	async function handlePublish(workshop: Workshop) {
		publishMutation.mutate(workshop.id);
	}

	async function handleCancel(workshop: Workshop) {
		if (!confirm(`Are you sure you want to cancel "${workshop.title}"?`)) return;
		cancelMutation.mutate(workshop.id);
	}
</script>

<div class="p-6 space-y-6">
	<div class="flex justify-between items-center">
		<h1 class="text-3xl font-bold">Workshops</h1>
		<Button onclick={handleCreate}>Create Workshop</Button>
	</div>

	{#if workshopsQuery.error}
		<Alert variant="destructive">
			<AlertDescription>{workshopsQuery.error?.message || String(workshopsQuery.error)}</AlertDescription>
		</Alert>
	{/if}

	{#if deleteMutation.error}
		<Alert variant="destructive">
			<AlertDescription>{deleteMutation.error?.message || String(deleteMutation.error)}</AlertDescription>
		</Alert>
	{/if}

	{#if publishMutation.error}
		<Alert variant="destructive">
			<AlertDescription>{publishMutation.error?.message || String(publishMutation.error)}</AlertDescription>
		</Alert>
	{/if}

	{#if cancelMutation.error}
		<Alert variant="destructive">
			<AlertDescription>{cancelMutation.error?.message || String(cancelMutation.error)}</AlertDescription>
		</Alert>
	{/if}
	<WorkshopCalendar
		handleEdit={handleEdit}
		handleDelete={handleDelete}
		handlePublish={handlePublish}
		handleCancel={handleCancel}
		isLoading={workshopsQuery.isLoading}
		workshops={workshopsQuery.data ??[]} {userId} />
</div>
