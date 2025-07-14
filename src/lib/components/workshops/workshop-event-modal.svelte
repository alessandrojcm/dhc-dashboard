<script lang="ts">
	import { Button } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import { Calendar, Users, MapPin } from 'lucide-svelte';
	import dayjs from 'dayjs';
	import type { WorkshopCalendarEvent } from '$lib/types';


	let { calendarEvent: event }: { calendarEvent: WorkshopCalendarEvent } = $props();

	// Find the workshop data from the event
	const workshop = event.workshop;
	const interestCount = workshop?.interest_count?.at(0)?.interest_count ?? 0;
	const hasInterest = event.isInterested;
	const onInterestToggle = event.onInterestToggle;

	const handleInterestToggle = () => {
		if (onInterestToggle && workshop?.id) {
			onInterestToggle(workshop.id);
		}
	};

	const formatDateTime = (dateString: string) => {
		return dayjs(dateString).format('MMM DD, YYYY at h:mm A');
	};
</script>

<div class="workshop-event-modal">
	<div class="modal-header">
		<h2 class="text-xl font-semibold">{workshop?.title || event?.title || 'Workshop'}</h2>
		<Badge variant="secondary">Planned</Badge>
	</div>

	<div class="modal-content space-y-4">
		<!-- Date and Time -->
		<div class="flex items-center gap-2 text-sm">
			<Calendar class="w-4 h-4" />
			<span>{formatDateTime(workshop?.start_date || event?.start)}
				- {formatDateTime(workshop?.end_date || event?.end)}</span>
		</div>

		<!-- Location -->
		{#if workshop?.location || event?.location}
			<div class="flex items-center gap-2 text-sm">
				<MapPin class="w-4 h-4" />
				<span>{workshop?.location || event?.location}</span>
			</div>
		{/if}

		<!-- Interest Count -->
		<div class="flex items-center gap-2 text-sm">
			<Users class="w-4 h-4" />
			<span>{interestCount} {interestCount === 1 ? 'person' : 'people'} interested</span>
		</div>

		<!-- Description -->
		{#if workshop?.description || event?.description}
			<div class="text-sm text-muted-foreground">
				<p>{workshop?.description || event?.description}</p>
			</div>
		{/if}

		<!-- Interest Button -->
		<div class="flex justify-end pt-4">
			<Button
				variant={hasInterest ? "primary" : "outline"}
				onclick={handleInterestToggle}
				disabled={event.isLoading}
			>
				{hasInterest ? 'Withdraw Interest' : 'Express Interest'}
			</Button>
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
