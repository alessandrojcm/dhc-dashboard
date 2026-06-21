<script lang="ts">
import { page } from "$app/state";
import { createQuery, useQueryClient } from "@tanstack/svelte-query";
import {
	workshopsAttendeesOptions,
	workshopsAttendeesQueryKey,
	type WorkshopAttendeesResponse,
} from "@dhc/api-client";
import {
	Card,
	CardContent,
	CardHeader,
	CardTitle,
} from "$lib/components/ui/card";
import AttendeeManager from "$lib/components/workshops/attendee-manager.svelte";

let { data } = $props();
const workshopId = page.params.id!;
const queryClient = useQueryClient();

// Single Phoenix read (`GET /api/workshops/{id}/attendees`) via the generated
// TanStack Query options. The Supabase JWT is attached by `configureClient`'s
// `getAuthToken` hook; authz is enforced by Phoenix's `workshop_management_api`
// pipeline, so no SvelteKit `authorize()` gate is needed. Replaces the two
// browser-side PostgREST joins over `club_activity_registrations` /
// `club_activity_refunds` with the normalized combined DTO (`participant.type`
// / `displayName` / `email` instead of `user_profiles` / `external_users`
// join shapes). `initialData` is the SSR envelope from `+page.server.ts`.
const attendeesQuery = createQuery(() => ({
	...workshopsAttendeesOptions({ path: { id: workshopId } }),
	initialData: data.attendeesResponse as WorkshopAttendeesResponse | undefined,
}));

const payload = $derived(attendeesQuery.data?.data);
const attendees = $derived(payload?.attendees ?? []);
const refunds = $derived(payload?.refunds ?? []);
const workshop = $derived(payload?.workshop);

function invalidateAttendees() {
	queryClient.invalidateQueries({
		queryKey: workshopsAttendeesQueryKey({ path: { id: workshopId } }),
	});
}
</script>

<div class="container mx-auto py-6">
	<div class="mb-6">
		<h1 class="text-3xl font-bold">Workshop Attendees</h1>
		<p class="text-muted-foreground">Manage attendance and process refunds</p>
	</div>

	<Card>
		<CardHeader>
			<CardTitle>Registered Attendees</CardTitle>
		</CardHeader>
		<CardContent>
			{#if attendeesQuery.isLoading}
				<div class="flex items-center justify-center py-8">
					<div class="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
				</div>
			{:else if attendeesQuery.error}
				<div class="text-center py-8 text-destructive">Failed to load data</div>
			{:else if workshop}
				<AttendeeManager
					{attendees}
					{refunds}
					{workshop}
					{workshopId}
					onAttendanceUpdated={() => {
						invalidateAttendees();
					}}
					onRefundProcessed={() => {
						invalidateAttendees();
					}}
				/>
			{/if}
		</CardContent>
	</Card>
</div>
