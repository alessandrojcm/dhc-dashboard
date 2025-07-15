<script lang="ts">
	import { Button } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import { Calendar, Users, MapPin, X } from 'lucide-svelte';
	import dayjs from 'dayjs';
	import type { WorkshopCalendarEvent } from '$lib/types';
	import Dinero from 'dinero.js';


	let { calendarEvent: event, onInterestToggle, onClose }: { 
		calendarEvent: WorkshopCalendarEvent;
		onInterestToggle?: (workshopId: string) => void;
		onClose?: () => void;
	} = $props();

	// Find the workshop data from the event
	const { handleEdit, handlePublish, handleCancel, handleDelete } = event;
	const workshop = event.workshop;
	const interestCount = workshop?.interest_count?.at(0)?.interest_count ?? 0;
	const isInterested = event.isInterested;


	const formatDateTime = (dateString: string) => {
		return dayjs(dateString).format('MMM DD, YYYY at h:mm A');
	};

	function formatPrice(price: number) {
		return Dinero({ amount: price, currency: 'EUR' }).toFormat();
	}
</script>

<div class="workshop-event-modal drop-shadow-accent">
	<div class="modal-header">
		<h2 class="text-xl font-semibold">{workshop?.title || event?.title || 'Workshop'}</h2>
		<div class="flex items-center gap-2">
			<Badge variant="secondary">Planned</Badge>
			{#if onClose}
				<Button variant="ghost" size="sm" onclick={onClose} class="h-6 w-6 p-0">
					<X class="h-4 w-4" />
				</Button>
			{/if}
		</div>
	</div>

	<div class="modal-content space-y-4">
		<!-- Date and Time -->
		<div class="flex items-center gap-2 text-sm">
			<Calendar class="w-4 h-4" />
			<span>{formatDateTime(workshop?.start_date || event?.start)}
				- {formatDateTime(workshop?.end_date || event?.end)}</span>
		</div>

		<!-- Location -->
		{#if workshop?.location}
			<div class="flex items-center gap-2 text-sm">
				<MapPin class="w-4 h-4" />
				<span>{workshop.location}</span>
			</div>
		{/if}

		<!-- Interest Count -->
		<div class="flex items-center gap-2 text-sm">
			<Users class="w-4 h-4" />
			<span>{interestCount} {interestCount === 1 ? 'person' : 'people'} interested</span>
		</div>

		<!-- Description -->
		{#if workshop?.description}
			<div class="text-sm text-muted-foreground">
				<p>{workshop.description}</p>
			</div>
		{/if}
		<!--Price-->
		<div class="flex items-center gap-2 text-sm">
			<strong>Member Price:</strong> {formatPrice(workshop.price_member)}
			{#if workshop.is_public}
				<div>
					<strong>Non-Member Price:</strong> {formatPrice(workshop.price_non_member)}
				</div>
			{/if}
		</div>


		<div class="flex justify-between items-center pt-4">
			<!-- Interest Toggle Button (for members) -->
			{#if onInterestToggle && workshop.status === 'planned'}
				<Button 
					variant={isInterested ? "default" : "outline"} 
					size="sm" 
					onclick={() => onInterestToggle?.(workshop.id)}
				>
					{isInterested ? 'Interested' : 'Express Interest'}
				</Button>
			{:else}
				<div></div>
			{/if}

			<!-- Admin Actions -->
			<div class="flex gap-2">
				{#if handleEdit}
					<Button variant="outline" size="sm" onclick={() => handleEdit(workshop)}>
						Edit
					</Button>
				{/if}

				{#if handlePublish && workshop.status === 'planned'}
					<Button variant="default" class="text-white" size="sm" onclick={() => handlePublish(workshop)}>
						Publish
					</Button>
				{/if}

				{#if handleCancel && (workshop.status === 'planned' || workshop.status === 'published')}
					<Button variant="destructive" class="text-white" size="sm" onclick={() => handleCancel(workshop)}>
						Cancel
					</Button>
				{/if}

				{#if handleDelete && workshop.status === 'planned'}
					<Button variant="destructive" class="text-white" size="sm" onclick={() => handleDelete(workshop)}>
						Delete
					</Button>
				{/if}
			</div>
		</div>
	</div>
</div>

<style>
    .workshop-event-modal {
        padding: 1.5rem;
        max-width: 400px;
        width: 100%;
    }

    .modal-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 1rem;
    }

    .modal-content {
        display: flex;
        flex-direction: column;
    }
</style>
