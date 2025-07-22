<script lang="ts">
	import { createMutation } from '@tanstack/svelte-query';
	import { Button, buttonVariants } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import * as Dialog from '$lib/components/ui/dialog';
	import * as Select from '$lib/components/ui/select';
	import { Textarea } from '$lib/components/ui/textarea';
	import { Label } from '$lib/components/ui/label';
	import { toast } from 'svelte-sonner';

	interface Props {
		refunds: any[];
		attendees: any[];
		workshopId: string;
		onRefundProcessed?: () => void;
	}

	let { refunds, attendees, workshopId, onRefundProcessed }: Props = $props();

	let selectedRegistrationId = $state('');
	let refundReason = $state('');
	let showRefundDialog = $state(false);

	const processRefundMutation = createMutation(() => ({
		mutationFn: async (data: { registration_id: string; reason: string }) => {
			const response = await fetch(`/api/workshops/${workshopId}/refunds`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(data)
			});

			if (!response.ok) {
				const error = await response.json();
				throw new Error(error.error || 'Failed to process refund');
			}

			return response.json();
		},
		onSuccess: () => {
			showRefundDialog = false;
			selectedRegistrationId = '';
			refundReason = '';
			onRefundProcessed?.();
		},
		onError: (error: any) => {
			toast.error(error.message);
		}
	}));

	function processRefund() {
		if (!selectedRegistrationId || !refundReason.trim()) {
			toast.error('Please select an attendee and provide a reason');
			return;
		}

		processRefundMutation.mutate({
			registration_id: selectedRegistrationId,
			reason: refundReason.trim()
		});
	}

	function getStatusBadgeVariant(status: string) {
		switch (status) {
			case 'completed': return 'default';
			case 'processing': return 'secondary';
			case 'failed': return 'destructive';
			case 'cancelled': return 'outline';
			default: return 'secondary';
		}
	}

	function getAttendeeDisplayName(attendee: any) {
		return attendee.user_profiles?.first_name 
			? `${attendee.user_profiles.first_name} ${attendee.user_profiles.last_name}`
			: `${attendee.external_users?.first_name} ${attendee.external_users?.last_name}`;
	}

	function formatCurrency(amount: number) {
		return new Intl.NumberFormat('en-IE', {
			style: 'currency',
			currency: 'EUR'
		}).format(amount);
	}

	// Filter out attendees who already have refunds
	const eligibleAttendees = $derived(attendees.filter(attendee => 
		!refunds.some(refund => refund.registration_id === attendee.id)
	));

	// Derived value for select trigger content
	const selectedAttendee = $derived(eligibleAttendees.find(a => a.id === selectedRegistrationId));
	const triggerContent = $derived(selectedAttendee ? getAttendeeDisplayName(selectedAttendee) : "Choose attendee...");
</script>

<div class="space-y-4">
	<!-- Process New Refund -->
	<Dialog.Root bind:open={showRefundDialog}>
		<Dialog.Trigger class={buttonVariants({ variant: "outline" }) + " w-full"}>
			Process Refund
		</Dialog.Trigger>
		<Dialog.Content>
			<Dialog.Header>
				<Dialog.Title>Process Refund</Dialog.Title>
			</Dialog.Header>
			
			<div class="space-y-4">
				<div>
					<Label for="attendee-select">Select Attendee</Label>
					<Select.Root type="single" bind:value={selectedRegistrationId}>
						<Select.Trigger>
							{triggerContent}
						</Select.Trigger>
						<Select.Content>
							{#each eligibleAttendees as attendee (attendee.id)}
								<Select.Item value={attendee.id} label={getAttendeeDisplayName(attendee)}>
									{getAttendeeDisplayName(attendee)}
								</Select.Item>
							{/each}
						</Select.Content>
					</Select.Root>
				</div>
				
				<div>
					<Label for="refund-reason">Reason for Refund</Label>
					<Textarea
						id="refund-reason"
						placeholder="Enter reason for refund..."
						bind:value={refundReason}
						rows={3}
					/>
				</div>
				
				<div class="flex justify-end gap-2">
					<Button variant="outline" onclick={() => showRefundDialog = false}>
						Cancel
					</Button>
					<Button 
						onclick={processRefund}
						disabled={processRefundMutation.isPending}
					>
						{#if processRefundMutation.isPending}
							Processing...
						{:else}
							Process Refund
						{/if}
					</Button>
				</div>
			</div>
		</Dialog.Content>
	</Dialog.Root>
	
	<!-- Existing Refunds -->
	{#if refunds.length > 0}
		<div class="space-y-2">
			<h4 class="font-medium">Existing Refunds</h4>
			{#each refunds as refund (refund.id)}
				{@const attendee = attendees.find(a => a.id === refund.registration_id)}
				<div class="p-3 border rounded-lg">
					<div class="flex items-center justify-between">
						<div>
							<div class="font-medium text-sm">
								{attendee ? getAttendeeDisplayName(attendee) : 'Unknown'}
							</div>
							<div class="text-xs text-muted-foreground">
								{formatCurrency(refund.refund_amount / 100)}
							</div>
						</div>
						<Badge variant={getStatusBadgeVariant(refund.status)}>
							{refund.status}
						</Badge>
					</div>
					{#if refund.refund_reason}
						<div class="text-xs text-muted-foreground mt-1">
							{refund.refund_reason}
						</div>
					{/if}
				</div>
			{/each}
		</div>
	{:else}
		<div class="text-center py-4 text-muted-foreground text-sm">
			No refunds processed yet
		</div>
	{/if}
</div>
