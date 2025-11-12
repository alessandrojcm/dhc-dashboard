<script lang="ts">
	import { page } from '$app/state';
	import { createQuery, useQueryClient } from '@tanstack/svelte-query';
	import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/ui/card';
	import AttendeeManager from '$lib/components/workshops/attendee-manager.svelte';
	import { toast } from 'svelte-sonner';

	let { data } = $props();
	const supabase = data.supabase;
	const workshopId = page.params.id;
	const queryClient = useQueryClient();

	// Use preloaded data with TanStack Query for cache management and refetching
	const attendeesQuery = createQuery(() => ({
		queryKey: ['workshop-attendees', workshopId],
		queryFn: async () => {
			// Refetch from server if needed
			const { data, error } = await supabase
				.from('club_activity_registrations')
				.select(
					`
					id,
					club_activity_id,
					status,
					attendance_status,
					attendance_marked_at,
					attendance_marked_by,
					attendance_notes,
					user_profiles!club_activity_registrations_member_user_id_fkey (
						first_name,
						last_name
					),
					external_users!club_activity_registrations_external_user_id_fkey (
						first_name,
						last_name,
						email
					)
				`
				)
				.eq('club_activity_id', workshopId)
				.in('status', ['confirmed', 'pending'])
				.order('created_at', { ascending: true });

			if (error) throw error;
			return data;
		},
		initialData: data.attendees
	}));

	const refundsQuery = createQuery(() => ({
		queryKey: ['workshop-refunds', workshopId],
		queryFn: async () => {
			// Refetch from server if needed - transform to match server loader structure
			const { data: refundsData, error } = await supabase
				.from('club_activity_refunds')
				.select(
					`
					id,
					registration_id,
					refund_amount,
					refund_reason,
					status,
					created_at,
					club_activity_registrations!inner (
						club_activity_id,
						user_profiles (
							first_name,
							last_name
						),
						external_users (
							first_name,
							last_name,
							email
						)
					)
				`
				)
				.eq('club_activity_registrations.club_activity_id', workshopId)
				.order('created_at', { ascending: false });

			if (error) throw error;
			return (
				refundsData?.map((refund) => ({
					id: refund.id,
					registration_id: refund.registration_id,
					refund_amount: refund.refund_amount,
					refund_reason: refund.refund_reason,
					status: refund.status,
					created_at: refund.created_at,
					user_profiles: refund.club_activity_registrations?.user_profiles || null,
					external_users: refund.club_activity_registrations?.external_users || null
				})) || []
			);
		},
		initialData: data.refunds // Use preloaded data
	}));
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
			{#if attendeesQuery.isLoading || refundsQuery.isLoading}
				<div class="flex items-center justify-center py-8">
					<div class="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
				</div>
			{:else if attendeesQuery.error || refundsQuery.error}
				<div class="text-center py-8 text-destructive">Failed to load data</div>
			{:else}
				<AttendeeManager
					attendees={attendeesQuery.data || []}
					refunds={refundsQuery.data || []}
					workshop={data.workshop}
					{workshopId}
					onAttendanceUpdated={() => {
						queryClient.invalidateQueries({ queryKey: ['workshop-attendees', workshopId] });
					}}
					onRefundProcessed={() => {
						queryClient.invalidateQueries({ queryKey: ['workshop-refunds', workshopId] });
						queryClient.invalidateQueries({ queryKey: ['workshop-attendees', workshopId] });
					}}
				/>
			{/if}
		</CardContent>
	</Card>
</div>
