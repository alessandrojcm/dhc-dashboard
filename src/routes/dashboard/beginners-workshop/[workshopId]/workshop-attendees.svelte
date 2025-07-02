<script lang="ts">
	import {
		Root as SelectRoot,
		Trigger as SelectTrigger,
		Content as SelectContent,
		Item as SelectItem
	} from '$lib/components/ui/select';
	import { Badge } from '$lib/components/ui/badge';
	import { User } from 'lucide-svelte';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import dayjs from 'dayjs';
	import type { SupabaseClient } from '@supabase/supabase-js';
	import { createQuery, useQueryClient } from '@tanstack/svelte-query';
	import { page } from '$app/state';
	import { onDestroy } from 'svelte';

	let { supabase }: { supabase: SupabaseClient } = $props();
	const workshopId = page.params.workshopId;
	let statusFilter = $state('all');
	const queryClient = useQueryClient();

	// Fetch coolOffDays from the workshop
	const workshopQuery = createQuery(() => ({
		queryKey: ['workshop-cooloff', workshopId],
		enabled: !!workshopId,
		queryFn: async () => {
			if (!workshopId) return null;
			const { data, error } = await supabase
				.from('workshops')
				.select('id, cool_off_days')
				.eq('id', workshopId)
				.single();
			if (error) throw error;
			return data;
		}
	}));
	const coolOffDays = workshopQuery.data?.cool_off_days ?? 5;


	type WorkshopAttendee = {
		id: any;
		status: any;
		invited_at: any;
		user_profile_id: any;
		checked_in_at: any;
		paid_at: any;
		onboarding_completed_at: any;
		user_profiles: {
			first_name: any;
			last_name: any;
		};
	}

	function getAttendees(signal: AbortSignal) {
		if (!workshopId) return [];
		let query = supabase
			.from('workshop_attendees')
			.select('id, status, invited_at, user_profile_id, checked_in_at, paid_at, onboarding_completed_at, user_profiles(first_name, last_name)')
			.eq('workshop_id', workshopId);
		if (statusFilter !== 'all') {
			query = query.eq('status', statusFilter);
		}
		return query.abortSignal(signal).throwOnError();
	}

	const attendeesQuery = createQuery(() => ({
		queryKey: ['workshop-attendees', workshopId, statusFilter],
		enabled: !!workshopId,
		queryFn: async ({ signal }) => {
			return getAttendees(signal) as WorkshopAttendee[];
		}
	}));

	function coolOffPassed(emailedAt: string) {
		return dayjs().diff(dayjs(emailedAt), 'day') > coolOffDays;
	}

	function getProfileName(user_profiles: WorkshopAttendee['user_profiles']): string {
		if (!user_profiles) return '';
		return `${user_profiles.first_name ?? ''} ${user_profiles.last_name ?? ''}`.trim();
	}

	function statusColor(status: string) {
		if (status === 'confirmed' || status === 'attended') return 'success';
		if (status === 'invited') return 'info';
		if (status === 'cancelled' || status === 'no_show') return 'destructive';
		return 'outline';
	}

	// Set up real-time subscription for workshop attendees status changes
	let realtimeChannel: any = null;

	$effect(() => {
		if (!workshopId || !supabase) return;

		// Create realtime subscription
		realtimeChannel = supabase
			.channel(`workshop-attendees-${workshopId}`)
			.on(
				'postgres_changes',
				{
					event: 'UPDATE',
					schema: 'public',
					table: 'workshop_attendees',
					filter: `workshop_id=eq.${workshopId}`
				},
				(payload) => {
					console.log('Realtime update received:', payload);

					// Update the query cache with the new status
					queryClient.setQueryData(['workshop-attendees', workshopId, statusFilter], (oldData: WorkshopAttendee[] | undefined) => {
						if (!oldData) return oldData;

						return oldData.map(attendee => {
							if (attendee.id === payload.new.id) {
								return {
									...attendee,
									status: payload.new.status,
									checked_in_at: payload.new.checked_in_at,
									paid_at: payload.new.paid_at,
									onboarding_completed_at: payload.new.onboarding_completed_at
								};
							}
							return attendee;
						});
					});

					// Also update cache for 'all' filter if we're currently filtering
					if (statusFilter !== 'all') {
						queryClient.setQueryData(['workshop-attendees', workshopId, 'all'], (oldData: WorkshopAttendee[] | undefined) => {
							if (!oldData) return oldData;

							return oldData.map(attendee => {
								if (attendee.id === payload.new.id) {
									return {
										...attendee,
										status: payload.new.status,
										checked_in_at: payload.new.checked_in_at,
										paid_at: payload.new.paid_at,
										onboarding_completed_at: payload.new.onboarding_completed_at
									};
								}
								return attendee;
							});
						});
					}
				}
			)
			.subscribe();

		// Cleanup function
		return () => {
			if (realtimeChannel) {
				supabase.removeChannel(realtimeChannel);
				realtimeChannel = null;
			}
		};
	});

	// Cleanup on component destroy
	onDestroy(() => {
		if (realtimeChannel) {
			supabase.removeChannel(realtimeChannel);
		}
	});
</script>

<div class="bg-card border rounded-lg shadow-md p-6 h-full flex flex-col">
	<div class="flex items-center justify-between mb-4 gap-2 flex-wrap">
		<div class="flex items-center gap-2">
			<h3 class="font-bold text-lg">Attendees</h3>
			<Badge variant="secondary"
						 class="text-xs px-2 py-1">{attendeesQuery.data ? attendeesQuery.data.length : 0}</Badge>
		</div>
		<SelectRoot type="single" value={statusFilter} onValueChange={(v) => statusFilter = v}>
			<SelectTrigger class="w-36 h-8 text-xs border" aria-label="Filter by status">
				<span
					class="mr-2">{statusFilter === 'all' ? 'All Statuses' : statusFilter.charAt(0).toUpperCase() + statusFilter.slice(1)}</span>
			</SelectTrigger>
			<SelectContent>
				<SelectItem value="all">All</SelectItem>
				<SelectItem value="invited">Invited</SelectItem>
				<SelectItem value="confirmed">Confirmed</SelectItem>
				<SelectItem value="attended">Attended</SelectItem>
			</SelectContent>
		</SelectRoot>
	</div>
	<div class="flex-1 overflow-y-auto divide-y">
		{#if !workshopId}
			<div class="flex flex-col items-center justify-center h-48 text-muted-foreground text-sm py-8 text-center">
				<User class="w-8 h-8 mb-2 opacity-60" />
				Select a workshop to view attendees
			</div>
		{:else if attendeesQuery.isLoading || workshopQuery.isLoading}
			<div class="flex flex-col items-center justify-center h-48 text-muted-foreground text-sm py-8 text-center">
				<LoaderCircle class="w-6 h-6 mb-2 animate-spin" />
				Loading attendees...
			</div>
		{:else if attendeesQuery.isError || workshopQuery.isError}
			<div class="flex flex-col items-center justify-center h-48 text-red-600 text-sm py-8 text-center">
				Error loading attendees or workshop info
			</div>
		{:else if !attendeesQuery.data || attendeesQuery.data.length === 0}
			<div class="flex flex-col items-center justify-center h-48 text-muted-foreground text-sm py-8 text-center">
				<User class="w-8 h-8 mb-2 opacity-60" />
				No attendees found for this workshop
			</div>
		{:else}
			<ul class="divide-y">
				{#each attendeesQuery.data as attendee}
					<li class="flex items-center justify-between py-4 gap-2">
						<div>
							<div class="font-medium text-base">{getProfileName(attendee.user_profiles)}</div>
							<div class="text-xs text-muted-foreground">
								{#if attendee.invited_at}
									Emailed: {dayjs(attendee.invited_at).format('YYYY-MM-DD')}
								{:else}
									Not yet invited
								{/if}
							</div>
						</div>
						<div class="flex flex-col items-end gap-1 min-w-[110px]">
							<Badge variant={statusColor(attendee.status)} class="text-xs capitalize">{attendee.status}</Badge>
							<span class="text-xs">
                {#if attendee.invited_at}
                  {coolOffPassed(attendee.invited_at)
										? 'Cool-off passed'
										: `In cool-off (${coolOffDays - dayjs().diff(dayjs(attendee.invited_at), 'day')}d left)`}
                {:else}
                  Manual attendee
                {/if}
              </span>
						</div>
					</li>
				{/each}
			</ul>
		{/if}
	</div>
</div> 
