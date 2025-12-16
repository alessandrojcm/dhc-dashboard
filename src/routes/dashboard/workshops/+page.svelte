<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { Button } from '$lib/components/ui/button';
	import { Alert, AlertDescription } from '$lib/components/ui/alert';
	import WorkshopCalendar from '$lib/components/workshops/workshop-calendar.svelte';
	import QuickCreateWorkshop from '$lib/components/workshops/quick-create-workshop.svelte';
	import type { ClubActivityWithRegistrations } from '$lib/types';
	import { createQuery } from '@tanstack/svelte-query';

	// Improvement: add pagination by month
	let { data } = $props();
	const supabase = data.supabase;
	const userId = data!.user!.id;
	const workshopsQuery = createQuery(() => ({
		queryKey: ['workshops'],
		refetchOnMount: true,
		queryFn: async ({ signal }) => {
			const { data, error } = await supabase
				.from('club_activities')
				.select(
					`
					*,
					interest_count:club_activity_interest_counts(interest_count),
					user_interest:club_activity_interest(user_id),
					user_registrations:club_activity_registrations(member_user_id, status)
				`
				)
				.neq('status', 'cancelled')
				.abortSignal(signal);

			if (error) throw error;
			return data as ClubActivityWithRegistrations[];
		}
	}));

	// Simple handlers - mutations are now handled in the modal component

	function handleCreate() {
		goto(resolve('/dashboard/workshops/create'));
	}

	function handleEdit(workshop: ClubActivityWithRegistrations) {
		goto(resolve(`/dashboard/workshops/${workshop.id}/edit`));
	}

	// Only edit handler needed - mutations are handled in the modal
</script>

<div class="p-6 space-y-6">
	<div class="flex justify-between items-center">
		<h1 class="text-3xl font-bold">Workshops</h1>
		<div class="flex gap-2">
			<QuickCreateWorkshop />
			<Button onclick={handleCreate}>Create Workshop</Button>
		</div>
	</div>

	{#if workshopsQuery.error}
		<Alert variant="destructive">
			<AlertDescription
				>{workshopsQuery.error?.message || String(workshopsQuery.error)}</AlertDescription
			>
		</Alert>
	{/if}

	<!-- Error handling is now done in the modal component with toast notifications -->
	<WorkshopCalendar
		{handleEdit}
		isLoading={workshopsQuery.isLoading}
		workshops={workshopsQuery.data ?? []}
		{userId}
	/>
</div>
