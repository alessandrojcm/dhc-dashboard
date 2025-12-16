<script lang="ts">
	import * as AlertDialog from '$lib/components/ui/alert-dialog';
	import { createMutation } from '@tanstack/svelte-query';
	import {
		checkRefundEligibility,
		type RefundEligibilityResult
	} from '$lib/utils/refund-eligibility';
	import type { Database } from '$database';
	import { toast } from 'svelte-sonner';

	type ClubActivity = Database['public']['Tables']['club_activities']['Row'];

	interface Props {
		workshop: ClubActivity;
		registrationId: string;
		registrationStatus: string;
		open: boolean;
		onOpenChange: (open: boolean) => void;
		onSuccess: () => void;
	}

	let { workshop, registrationId, registrationStatus, open, onOpenChange, onSuccess }: Props =
		$props();

	const refundEligibility: RefundEligibilityResult = $derived(
		checkRefundEligibility(
			workshop.start_date,
			workshop.refund_days,
			workshop.status ?? 'planned',
			registrationStatus
		)
	);

	const cancelRegistrationMutation = createMutation(() => ({
		mutationFn: async () => {
			const response = await fetch(`/api/workshops/${workshop.id}/register`, {
				method: 'DELETE'
			});

			if (!response.ok) {
				const error = (await response.json()) as { error?: string };
				throw new Error(error.error || 'Failed to cancel registration');
			}

			return response.json();
		},
		onSuccess: () => {
			toast.success('Registration cancelled successfully');
			onSuccess();
			onOpenChange(false);
		},
		onError: (error) => {
			toast.error(error.message || 'Failed to cancel registration');
		}
	}));

	const requestRefundMutation = createMutation(() => ({
		mutationFn: async () => {
			const response = await fetch(`/api/workshops/${workshop.id}/refunds`, {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json'
				},
				body: JSON.stringify({
					registration_id: registrationId,
					reason: 'Requested by attendee'
				})
			});

			if (!response.ok) {
				const error = (await response.json()) as { error?: string };
				throw new Error(error.error || 'Failed to process refund');
			}

			return response.json();
		},
		onSuccess: () => {
			toast.success('Refund requested successfully');
			onSuccess();
			onOpenChange(false);
		},
		onError: (error) => {
			toast.error(error.message || 'Failed to process refund');
		}
	}));

	function handleConfirm() {
		if (refundEligibility.isEligible) {
			requestRefundMutation.mutate();
		} else {
			cancelRegistrationMutation.mutate();
		}
	}

	const isLoading = $derived(
		cancelRegistrationMutation.isPending || requestRefundMutation.isPending
	);
</script>

<AlertDialog.Root {open} {onOpenChange}>
	<AlertDialog.Content>
		<AlertDialog.Header>
			<AlertDialog.Title>Cancel Registration</AlertDialog.Title>
			<AlertDialog.Description>
				Are you sure you want to cancel your registration for "{workshop.title}"?
			</AlertDialog.Description>
		</AlertDialog.Header>

		<div class="my-4 p-4 rounded-lg bg-muted">
			{#if refundEligibility.isEligible}
				<div class="flex items-center gap-2 text-green-600">
					<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
						<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"
						></path>
					</svg>
					<span class="font-medium">Refund Eligible</span>
				</div>
				<p class="text-sm text-muted-foreground mt-2">
					Your payment will be refunded to your original payment method.
					{#if refundEligibility.daysUntilDeadline !== undefined}
						You have {refundEligibility.daysUntilDeadline} day{refundEligibility.daysUntilDeadline !==
						1
							? 's'
							: ''}
						left to request a refund.
					{/if}
				</p>
			{:else}
				<div class="flex items-center gap-2 text-red-600">
					<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
						<path
							stroke-linecap="round"
							stroke-linejoin="round"
							stroke-width="2"
							d="M6 18L18 6M6 6l12 12"
						></path>
					</svg>
					<span class="font-medium">No Refund Available</span>
				</div>
				<p class="text-sm text-muted-foreground mt-2">
					{refundEligibility.reason}. Your registration will be cancelled but no refund will be
					issued.
				</p>
			{/if}
		</div>

		<AlertDialog.Footer>
			<AlertDialog.Cancel disabled={isLoading}>Keep Registration</AlertDialog.Cancel>
			<AlertDialog.Action
				onclick={handleConfirm}
				disabled={isLoading}
				class="bg-destructive text-destructive-foreground hover:bg-destructive/90"
			>
				{#if isLoading}
					Processing...
				{:else if refundEligibility.isEligible}
					Cancel & Refund
				{:else}
					Cancel Registration
				{/if}
			</AlertDialog.Action>
		</AlertDialog.Footer>
	</AlertDialog.Content>
</AlertDialog.Root>
