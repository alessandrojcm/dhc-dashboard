<script lang="ts">
import { createQuery } from "@tanstack/svelte-query";
import { goto } from "$app/navigation";
import type { ClubActivityWithRegistrations } from "$lib/types";

// Improvement: add pagination by month
const { data } = $props();
const supabase = data.supabase;
const _userId = data?.user?.id;
const _workshopsQuery = createQuery(() => ({
	queryKey: ["workshops"],
	refetchOnMount: true,
	queryFn: async ({ signal }) => {
		const { data, error } = await supabase
			.from("club_activities")
			.select(
				`
					*,
					interest_count:club_activity_interest_counts(interest_count),
					user_interest:club_activity_interest(user_id),
					user_registrations:club_activity_registrations(member_user_id, status)
				`,
			)
			.neq("status", "cancelled")
			.abortSignal(signal);

		if (error) throw error;
		return data as ClubActivityWithRegistrations[];
	},
}));

// Simple handlers - mutations are now handled in the modal component

function _handleCreate() {
	goto("/dashboard/workshops/create");
}

function _handleEdit(workshop: ClubActivityWithRegistrations) {
	goto(`/dashboard/workshops/${workshop.id}/edit`);
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
