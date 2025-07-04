<script lang="ts">
	import {
		Root as SelectRoot,
		Trigger as SelectTrigger,
		Content as SelectContent,
		Item as SelectItem
	} from '$lib/components/ui/select';
	import { Badge } from '$lib/components/ui/badge';
	import { Button } from '$lib/components/ui/button';
	import { Checkbox } from '$lib/components/ui/checkbox';
	import {
		Dialog,
		DialogContent,
		DialogDescription,
		DialogFooter,
		DialogHeader,
		DialogTitle
	} from '$lib/components/ui/dialog';
	import { User, X, RefreshCw } from 'lucide-svelte';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import dayjs from 'dayjs';
	import type { SupabaseClient } from '@supabase/supabase-js';
	import { createQuery, createMutation, useQueryClient } from '@tanstack/svelte-query';
	import { page } from '$app/state';
	import { onDestroy } from 'svelte';
	import { toast } from 'svelte-sonner';

	let { supabase }: { supabase: SupabaseClient } = $props();
	const workshopId = page.params.workshopId;
	let statusFilter = $state('all');
	const queryClient = useQueryClient();

	// Dialog states
	let cancelDialogOpen = $state(false);
	let refundDialogOpen = $state(false);
	let selectedAttendee = $state<WorkshopAttendee | null>(null);
	let moveToWaitlist = $state(false);

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

	// Create mutations for cancellation and refund
	const cancelMutation = createMutation(() => ({
		mutationFn: async ({ attendeeId, reason, moveToWaitlist }: { attendeeId: string, reason: string, moveToWaitlist: boolean }) => {
			const response = await fetch(`/api/workshops/${workshopId}/attendees/${attendeeId}/cancel`, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
				},
				body: JSON.stringify({
					reason,
					moveToWaitlist
				})
			});

			if (!response.ok) {
				throw new Error('Failed to cancel attendee');
			}

			return response.json();
		},
		onSuccess: () => {
			// Refresh the query data
			queryClient.invalidateQueries({ queryKey: ['workshop-attendees', workshopId] });
			cancelDialogOpen = false;
			selectedAttendee = null;
			toast.success('Attendee cancelled successfully');
		},
		onError: (error) => {
			console.error('Error cancelling attendee:', error);
			toast.error('Failed to cancel attendee');
		}
	}));

	const refundMutation = createMutation(() => ({
		mutationFn: async ({ attendeeId, reason, moveToWaitlist }: { attendeeId: string, reason: string, moveToWaitlist: boolean }) => {
			const response = await fetch(`/api/workshops/${workshopId}/attendees/${attendeeId}/refund`, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
				},
				body: JSON.stringify({
					reason,
					moveToWaitlist
				})
			});

			if (!response.ok) {
				throw new Error('Failed to process refund');
			}

			return response.json();
		},
		onSuccess: () => {
			// Refresh the query data
			queryClient.invalidateQueries({ queryKey: ['workshop-attendees', workshopId] });
			refundDialogOpen = false;
			selectedAttendee = null;
			toast.success('Refund processed successfully');
		},
		onError: (error) => {
			console.error('Error processing refund:', error);
			toast.error('Failed to process refund');
		}
	}));


	type WorkshopAttendee = {
		id: any;
		status: any;
		invited_at: any;
		user_profile_id: any;
		checked_in_at: any;
		paid_at: any;
		onboarding_completed_at: any;
		cancelled_at: any;
		refund_processed_at: any;
		refund_requested: any;
		stripe_refund_id: any;
		user_profiles: {
			first_name: any;
			last_name: any;
		};
	}

	function getAttendees(signal: AbortSignal) {
		if (!workshopId) return [];
		let query = supabase
			.from('workshop_attendees')
			.select('id, status, invited_at, user_profile_id, checked_in_at, paid_at, onboarding_completed_at, cancelled_at, refund_processed_at, refund_requested, stripe_refund_id, user_profiles(first_name, last_name)')
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

	function openCancelDialog(attendee: WorkshopAttendee) {
		selectedAttendee = attendee;
		moveToWaitlist = false;
		cancelDialogOpen = true;
	}

	function openRefundDialog(attendee: WorkshopAttendee) {
		selectedAttendee = attendee;
		moveToWaitlist = false;
		refundDialogOpen = true;
	}
	function cancelAttendee() {
		if (!selectedAttendee || cancelMutation.isPending) return;

		cancelMutation.mutate({
			attendeeId: selectedAttendee.id,
			reason: 'Cancelled by admin',
			moveToWaitlist: moveToWaitlist
		});
	}

	function refundAttendee() {
		if (!selectedAttendee || refundMutation.isPending) return;

		if (!selectedAttendee.paid_at) {
			toast.error('This attendee has not paid yet');
			return;
		}

		refundMutation.mutate({
			attendeeId: selectedAttendee.id,
			reason: 'Refunded by admin',
			moveToWaitlist: moveToWaitlist
		});
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
									onboarding_completed_at: payload.new.onboarding_completed_at,
									cancelled_at: payload.new.cancelled_at,
									refund_processed_at: payload.new.refund_processed_at,
									refund_requested: payload.new.refund_requested,
									stripe_refund_id: payload.new.stripe_refund_id
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
										onboarding_completed_at: payload.new.onboarding_completed_at,
										cancelled_at: payload.new.cancelled_at,
										refund_processed_at: payload.new.refund_processed_at,
										refund_requested: payload.new.refund_requested,
										stripe_refund_id: payload.new.stripe_refund_id
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
				<SelectItem value="cancelled">Cancelled</SelectItem>
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
						<div class="flex-1">
							<div class="font-medium text-base">{getProfileName(attendee.user_profiles)}</div>
							<div class="text-xs text-muted-foreground">
								{#if attendee.invited_at}
									Emailed: {dayjs(attendee.invited_at).format('YYYY-MM-DD')}
								{:else}
									Not yet invited
								{/if}
								{#if attendee.paid_at}
									• Paid: {dayjs(attendee.paid_at).format('YYYY-MM-DD')}
								{/if}
								{#if attendee.cancelled_at}
									• Cancelled: {dayjs(attendee.cancelled_at).format('YYYY-MM-DD')}
								{/if}
								{#if attendee.refund_processed_at}
									• Refunded: {dayjs(attendee.refund_processed_at).format('YYYY-MM-DD')}
								{/if}
							</div>
						</div>
						<div class="flex items-center gap-2">
							{#if attendee.status !== 'cancelled'}
								<Button
									variant="outline"
									size="sm"
									class="h-8 w-8 p-0"
									onclick={() => openCancelDialog(attendee)}
									title="Cancel Attendee"
								>
									<X class="h-4 w-4" />
								</Button>
								{#if attendee.paid_at && !attendee.refund_processed_at}
									<Button
										variant="outline"
										size="sm"
										class="h-8 w-8 p-0"
										onclick={() => openRefundDialog(attendee)}
										title="Process Refund"
									>
										<RefreshCw class="h-4 w-4" />
									</Button>
								{/if}
							{/if}
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
						</div>
					</li>
				{/each}
			</ul>
		{/if}
	</div>
</div>

<!-- Cancellation Dialog -->
<Dialog bind:open={cancelDialogOpen}>
	<DialogContent class="sm:max-w-[425px]">
		<DialogHeader>
			<DialogTitle>Cancel Attendee</DialogTitle>
			<DialogDescription>
				Are you sure you want to cancel {selectedAttendee ? getProfileName(selectedAttendee.user_profiles) : ''}?
			</DialogDescription>
		</DialogHeader>
		<div class="grid gap-4 py-4">
			<div class="flex items-center space-x-2">
				<Checkbox id="moveToWaitlist" bind:checked={moveToWaitlist} />
				<label for="moveToWaitlist" class="text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70">
					{selectedAttendee?.paid_at ? 'Move to waitlist with priority for next workshop' : 'Move to waitlist'}
				</label>
			</div>
		</div>
		<DialogFooter>
			<Button variant="outline" onclick={() => cancelDialogOpen = false} disabled={cancelMutation.isPending}>
				Cancel
			</Button>
			<Button onclick={cancelAttendee} disabled={cancelMutation.isPending}>
				{cancelMutation.isPending ? 'Processing...' : 'Confirm Cancellation'}
			</Button>
		</DialogFooter>
	</DialogContent>
</Dialog>

<!-- Refund Dialog -->
<Dialog bind:open={refundDialogOpen}>
	<DialogContent class="sm:max-w-[425px]">
		<DialogHeader>
			<DialogTitle>Process Refund</DialogTitle>
			<DialogDescription>
				Are you sure you want to process a full refund for {selectedAttendee ? getProfileName(selectedAttendee.user_profiles) : ''}?
			</DialogDescription>
		</DialogHeader>
		<div class="grid gap-4 py-4">
			<div class="flex items-center space-x-2">
				<Checkbox id="refundMoveToWaitlist" bind:checked={moveToWaitlist} />
				<label for="refundMoveToWaitlist" class="text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70">
					Move to waitlist with priority for next workshop
				</label>
			</div>
		</div>
		<DialogFooter>
			<Button variant="outline" onclick={() => refundDialogOpen = false} disabled={refundMutation.isPending}>
				Cancel
			</Button>
			<Button onclick={refundAttendee} disabled={refundMutation.isPending}>
				{refundMutation.isPending ? 'Processing...' : 'Process Refund'}
			</Button>
		</DialogFooter>
	</DialogContent>
</Dialog> 
