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
	// TODO: edit workshop
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
				.neq('status', 'cancelled')
				.abortSignal(signal);

			if (error) throw error;
			return data;
		}
	}));

	// Simple handlers - mutations are now handled in the modal component

	function handleCreate() {
		goto('/dashboard/workshops/create');
	}

	function handleEdit(workshop: Workshop) {
		goto(`/dashboard/workshops/${workshop.id}/edit`);
	}

	// Only edit handler needed - mutations are handled in the modal
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

	<!-- Error handling is now done in the modal component with toast notifications -->
	<WorkshopCalendar
		handleEdit={handleEdit}
		isLoading={workshopsQuery.isLoading}
		workshops={workshopsQuery.data ??[]} {userId} />
</div>
