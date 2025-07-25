<script lang="ts">
	import { createMutation } from '@tanstack/svelte-query';
	import { Button } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import * as Popover from '$lib/components/ui/popover';
	import { toast } from 'svelte-sonner';
	import { Check, X, DollarSign, User } from 'lucide-svelte';
	import { checkRefundEligibility } from '$lib/utils/refund-eligibility';

	interface Props {
		attendees: any[];
		refunds: any[];
		workshop: any;
		workshopId: string;
		onAttendanceUpdated?: () => void;
		onRefundProcessed?: () => void;
	}
	let { attendees, refunds, workshop, workshopId, onAttendanceUpdated, onRefundProcessed }: Props = $props();

	let refundPopoverOpen = $state(false);
	let attendeeIdForRefund = $state('');

	const markAttendedMutation = createMutation(() => ({
		mutationFn: async (registrationId: string) => {
			const response = await fetch(`/api/workshops/${workshopId}/attendance`, {
				method: 'PUT',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					attendance_updates: [{
						registration_id: registrationId,
						attendance_status: 'attended',
						notes: ''
					}]
				})
			});

			if (!response.ok) {
				const error = await response.json();
				throw new Error(error.error || 'Failed to mark attendance');
			}

			return response.json();
		},
		onSuccess: () => {
			onAttendanceUpdated?.();
			toast.success('Marked as attended');
		},
		onError: (error: any) => {
			toast.error(error.message);
		}
	}));

	const processRefundMutation = createMutation(() => ({
		mutationFn: async (registrationId: string) => {
			const response = await fetch(`/api/workshops/${workshopId}/refunds`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({
					registration_id: registrationId,
					reason: 'Requested by user'
				})
			});

			if (!response.ok) {
				const error = await response.json();
				throw new Error(error.error || 'Failed to process refund');
			}

			return response.json();
		},
		onSuccess: () => {
			attendeeIdForRefund = '';
			refundPopoverOpen = false;
			onRefundProcessed?.();
			toast.success('Refund processed');
		},
		onError: (error: any) => {
			toast.error(error.message);
		}
	}));

	function getAttendeeDisplayName(attendee: any) {
		return attendee.user_profiles?.first_name
			? `${attendee.user_profiles.first_name} ${attendee.user_profiles.last_name}`
			: `${attendee.external_users?.first_name} ${attendee.external_users?.last_name}`;
	}

	function getAttendeeEmail(attendee: any) {
		return attendee.user_profiles?.email || attendee.external_users?.email;
	}

	function getStatusBadgeVariant(status: string) {
		switch (status) {
			case 'attended':
				return 'default';
			case 'no_show':
				return 'destructive';
			case 'excused':
				return 'secondary';
			default:
				return 'outline';
		}
	}

	function getRefund(attendeeId: string) {
		return refunds.find(refund => refund.registration_id === attendeeId);
	}

	function formatCurrency(amount: number) {
		return new Intl.NumberFormat('en-IE', {
			style: 'currency',
			currency: 'EUR'
		}).format(amount);
	}

	function getRefundEligibility(attendee: any) {
		return checkRefundEligibility(
			workshop.start_date,
			workshop.refund_days,
			workshop.status,
			attendee.status
		);
	}

	function confirmRefund() {
		processRefundMutation.mutate(attendeeIdForRefund);
	}
</script>

<div class="space-y-4">
	{#each attendees as attendee (attendee.id)}
		{@const refund = getRefund(attendee.id)}
		<div class="flex items-center justify-between p-4 border rounded-lg bg-card">
			<div class="flex items-center gap-4">
				<div class="flex-shrink-0">
					<div class="w-10 h-10 rounded-full bg-muted flex items-center justify-center">
						<User class="w-5 h-5 text-muted-foreground" />
					</div>
				</div>

				<div class="flex-1 min-w-0">
					<div class="font-medium text-sm">{getAttendeeDisplayName(attendee)}</div>
					<div class="text-xs text-muted-foreground truncate">
						{getAttendeeEmail(attendee)}
					</div>
					<div class="flex items-center gap-2 mt-1">
						<Badge variant={getStatusBadgeVariant(attendee.attendance_status)} class="text-xs capitalize">
							{attendee.attendance_status || 'pending'}
						</Badge>
						{#if refund}
							<Badge variant="secondary" class="text-xs">
								Refunded {formatCurrency(refund.refund_amount / 100)}
							</Badge>
						{/if}
					</div>
				</div>
			</div>

			<div class="flex items-center gap-2">
				{#if attendee.attendance_status !== 'attended'}
					<Button
						size="sm"
						variant="outline"
						onclick={() => markAttendedMutation.mutate(attendee.id)}
						disabled={markAttendedMutation.isPending}
						class="gap-1"
					>
						<Check class="w-4 h-4" />
						Mark Attended
					</Button>
				{/if}

				{#if !refund}
					<Popover.Root open={refundPopoverOpen}>
						<Popover.Trigger>
							<Button
								size="sm"
								variant="outline"
								onclick={() => {
									refundPopoverOpen = true;
									attendeeIdForRefund = attendee.id;
								}}
								disabled={processRefundMutation.isPending}
								class="gap-1"
							>
								<DollarSign class="w-4 h-4" />
								Refund
							</Button>
						</Popover.Trigger>
						<Popover.Content class="w-80">
							{@const eligibility = getRefundEligibility(attendee)}
							<div class="space-y-3">
								<h4 class="font-medium">Confirm Refund</h4>
								<p class="text-sm text-muted-foreground">
									{getAttendeeDisplayName(attendee)}
								</p>

								{#if eligibility.isEligible}
									<div class="text-sm">
										<p class="text-green-600 font-medium">✓ Eligible for refund</p>
										<p class="text-muted-foreground mt-1">
											The user will receive a full refund to their original payment method.
										</p>
									</div>
								{:else}
									<div class="text-sm">
										<p class="text-orange-600 font-medium">⚠ Not eligible for refund</p>
										<p class="text-muted-foreground mt-1">
											{eligibility.reason}. The user will be removed from the workshop without refund.
										</p>
									</div>
								{/if}

								<div class="flex justify-end gap-2">
									<Button
										size="sm"
										variant="outline"
										onclick={() => {
											refundPopoverOpen = false;
											attendeeIdForRefund = '';
										}}
									>
										Cancel
									</Button>
									<Button
										size="sm"
										onclick={confirmRefund}
										disabled={processRefundMutation.isPending}
									>
										{#if processRefundMutation.isPending}
											Processing...
										{:else}
											Confirm
										{/if}
									</Button>
								</div>
							</div>
						</Popover.Content>
					</Popover.Root>
				{/if}
			</div>
		</div>
	{/each}

	{#if attendees.length === 0}
		<div class="text-center py-8 text-muted-foreground">
			No attendees registered yet
		</div>
	{/if}
</div>

