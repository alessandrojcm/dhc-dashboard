<script lang="ts">
	import { Button, buttonVariants } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import * as Popover from '$lib/components/ui/popover';
	import { Calendar, Users, MapPin, Group, Loader2, AlertTriangle, CheckCircle } from 'lucide-svelte';
	import { createMutation, useQueryClient } from '@tanstack/svelte-query';
	import { toast } from 'svelte-sonner';
	import dayjs from 'dayjs';
	import type { WorkshopCalendarEvent } from '$lib/types';
	import Dinero from 'dinero.js';

	let { calendarEvent: event, onClose }: {
		calendarEvent: WorkshopCalendarEvent;
		onInterestToggle?: (workshopId: string) => void;
		onClose?: () => void;
	} = $props();

	const queryClient = useQueryClient();
	const workshop = event.workshop;
	const interestCount = workshop?.interest_count?.at(0)?.interest_count ?? 0;

	// Mutations for workshop actions with proper loading states
	const deleteMutation = createMutation(() => ({
		mutationFn: async (workshopId: string) => {
			const response = await fetch(`/api/workshops/${workshopId}`, {
				method: 'DELETE'
			});
			if (!response.ok) throw new Error('Failed to delete workshop');
			return response.json();
		},
		onSuccess: () => {
			queryClient.invalidateQueries({ queryKey: ['workshops'] });
			toast.success('Workshop deleted successfully');
			onClose?.();
		},
		onError: (error) => {
			toast.error(`Failed to delete workshop: ${error.message}`);
		}
	}));

	const publishMutation = createMutation(() => ({
		mutationFn: async (workshopId: string) => {
			const response = await fetch(`/api/workshops/${workshopId}/publish`, {
				method: 'POST'
			});
			if (!response.ok) throw new Error('Failed to publish workshop');
			return response.json();
		},
		onSuccess: () => {
			queryClient.invalidateQueries({ queryKey: ['workshops'] });
			toast.success('Workshop published successfully');
			onClose?.();
		},
		onError: (error) => {
			toast.error(`Failed to publish workshop: ${error.message}`);
		}
	}));

	const cancelMutation = createMutation(() => ({
		mutationFn: async (workshopId: string) => {
			const response = await fetch(`/api/workshops/${workshopId}/cancel`, {
				method: 'POST'
			});
			if (!response.ok) throw new Error('Failed to cancel workshop');
			return response.json();
		},
		onSuccess: () => {
			queryClient.invalidateQueries({ queryKey: ['workshops'] });
			toast.success('Workshop cancelled successfully');
			onClose?.();
		},
		onError: (error) => {
			toast.error(`Failed to cancel workshop: ${error.message}`);
		}
	}));


	function formatPrice(price: number) {
		return Dinero({ amount: price, currency: 'EUR' }).toFormat();
	}

	function handleEdit() {
		event.handleEdit?.(workshop);
		onClose?.();
	}

	function handlePublish() {
		publishMutation.mutate(workshop.id);
	}

	function handleCancel() {
		cancelMutation.mutate(workshop.id);
	}

	function handleDelete() {
		deleteMutation.mutate(workshop.id);
	}

	// State for popover controls
	let deletePopoverOpen = $state(false);
	let cancelPopoverOpen = $state(false);

	// Check if actions are actually provided
	const hasEditAction = $derived(!!event.handleEdit);
</script>

<div class="workshop-event-modal">
	<div class="modal-header p-6 pb-4">
		<div class="flex items-start justify-between">
			<div class="space-y-2">
				<h2
					class="text-xl font-semibold text-foreground leading-tight">{workshop?.title || event?.title || 'Workshop'}</h2>
				<div class="flex items-center gap-2">
					<Badge
						variant={workshop.status === 'planned' ? 'secondary' : workshop.status === 'published' ? 'default' : 'destructive'}
						class="text-xs">
						{workshop.status === 'planned' ? 'Planned' : workshop.status === 'published' ? 'Published' : 'Cancelled'}
					</Badge>
					{#if workshop.is_public}
						<Badge variant="outline" class="text-xs">Public</Badge>
					{/if}
				</div>
			</div>
		</div>
	</div>

	<div class="modal-content px-6 pb-6 space-y-5">
		<!-- Date and Time -->
		<div class="flex items-start gap-3">
			<div class="mt-0.5">
				<Calendar class="w-5 h-5 text-muted-foreground" />
			</div>
			<div class="space-y-1">
				<div class="font-medium text-foreground">
					{dayjs(workshop?.start_date || event?.start).format('dddd, MMM DD, YYYY')}
				</div>
				<div class="text-sm text-muted-foreground">
					{dayjs(workshop?.start_date || event?.start).format('h:mm A')}
					- {dayjs(workshop?.end_date || event?.end).format('h:mm A')}
				</div>
			</div>
		</div>

		<!-- Location -->
		{#if workshop?.location}
			<div class="flex items-center gap-3">
				<MapPin class="w-5 h-5 text-muted-foreground" />
				<span class="text-sm text-foreground">{workshop.location}</span>
			</div>
		{/if}

		<!-- Interest Count -->
		<div class="flex items-center gap-3">
			<Users class="w-5 h-5 text-muted-foreground" />
			<span class="text-sm text-foreground">{interestCount} {interestCount === 1 ? 'person' : 'people'}
				interested</span>
		</div>

		<!-- Description -->
		{#if workshop?.description}
			<div class="bg-muted/50 p-4 rounded-lg border">
				<p class="text-sm text-foreground leading-relaxed">{workshop.description}</p>
			</div>
		{/if}

		<!-- Pricing -->
		<div class="bg-gradient-to-r from-muted/30 to-muted/20 p-4 rounded-lg border space-y-3">
			<div class="flex items-center justify-between">
				<span class="text-sm font-medium text-foreground">Member Price:</span>
				<span class="text-lg font-bold text-foreground">{formatPrice(workshop.price_member)}</span>
			</div>
			{#if workshop.is_public}
				<div class="flex items-center justify-between">
					<span class="text-sm font-medium text-foreground">Non-Member Price:</span>
					<span class="text-lg font-bold text-foreground">{formatPrice(workshop.price_non_member)}</span>
				</div>
			{/if}
		</div>


		<!-- Admin Actions -->
		<div class="border-t border-border pt-5 -mx-6 px-6">
			<div class="flex flex-wrap gap-3">
				{#if hasEditAction}
					<Button variant="outline" size="sm" onclick={handleEdit}>
						Edit
					</Button>
				{/if}

				{#if workshop.status === 'published'}
					<Button variant="default" size="sm" href={`workshops/${workshop.id}/attendees`}>
						Manage attendees
					</Button>
				{/if}

				{#if workshop.status === 'planned'}
					<Button
						variant="default"
						size="sm"
						onclick={handlePublish}
						disabled={publishMutation.isPending}
					>
						{#if publishMutation.isPending}
							<Loader2 class="w-4 h-4 mr-2 animate-spin" />
						{:else}
							<CheckCircle class="w-4 h-4 mr-2" />
						{/if}
						Publish
					</Button>
				{/if}

				{#if workshop.status === 'planned' || workshop.status === 'published'}
					<Popover.Root bind:open={cancelPopoverOpen}>
						<Popover.Trigger class={buttonVariants({ variant: "destructive", size: "sm" })}
														 disabled={cancelMutation.isPending}>
							{#if cancelMutation.isPending}
								<Loader2 class="w-4 h-4 mr-2 animate-spin" />
							{:else}
								<AlertTriangle class="w-4 h-4 mr-2" />
							{/if}
							Cancel
						</Popover.Trigger>
						<Popover.Content class="w-80">
							<div class="space-y-3">
								<div class="space-y-2">
									<h4 class="font-medium">Cancel Workshop</h4>
									<p class="text-sm text-muted-foreground">
										Are you sure you want to cancel "{workshop.title}"? This action cannot be undone.
									</p>
								</div>
								<div class="flex justify-end gap-2">
									<Button variant="outline" size="sm" onclick={() => cancelPopoverOpen = false}>
										Keep Workshop
									</Button>
									<Button
										variant="destructive"
										size="sm"
										onclick={() => { handleCancel(); cancelPopoverOpen = false; }}
										disabled={cancelMutation.isPending}
									>
										{#if cancelMutation.isPending}
											<Loader2 class="w-4 h-4 mr-2 animate-spin" />
										{/if}
										Cancel Workshop
									</Button>
								</div>
							</div>
						</Popover.Content>
					</Popover.Root>
				{/if}

				{#if workshop.status === 'planned'}
					<Popover.Root bind:open={deletePopoverOpen}>
						<Popover.Trigger class={buttonVariants({ variant: "destructive", size: "sm" })}
														 disabled={deleteMutation.isPending}>
							{#if deleteMutation.isPending}
								<Loader2 class="w-4 h-4 mr-2 animate-spin" />
							{:else}
								<AlertTriangle class="w-4 h-4 mr-2" />
							{/if}
							Delete
						</Popover.Trigger>
						<Popover.Content class="w-80 bg-white">
							<div class="space-y-3">
								<div class="space-y-2">
									<h4 class="font-medium">Delete Workshop</h4>
									<p class="text-sm text-muted-foreground">
										Are you sure you want to permanently delete "{workshop.title}"? This action cannot be undone.
									</p>
								</div>
								<div class="flex justify-end gap-2">
									<Button variant="outline" size="sm" onclick={() => deletePopoverOpen = false}>
										Keep Workshop
									</Button>
									<Button
										variant="destructive"
										size="sm"
										onclick={() => { handleDelete(); deletePopoverOpen = false; }}
										disabled={deleteMutation.isPending}
									>
										{#if deleteMutation.isPending}
											<Loader2 class="w-4 h-4 mr-2 animate-spin" />
										{/if}
										Delete Workshop
									</Button>
								</div>
							</div>
						</Popover.Content>
					</Popover.Root>
				{/if}
			</div>
		</div>
	</div>
</div>

<style>
    .workshop-event-modal {
        width: 100%;
    }
</style>
