<script lang="ts">
	import { ScheduleXCalendar } from '@schedule-x/svelte';
	import { createCalendar, createViewMonthGrid, createViewWeek } from '@schedule-x/calendar';
	import { createEventsServicePlugin } from '@schedule-x/events-service';
	import { createScrollControllerPlugin } from '@schedule-x/scroll-controller';
	import { createEventModalPlugin } from '@schedule-x/event-modal';
	import '@schedule-x/theme-shadcn/dist/index.css';
	import { Badge } from '$lib/components/ui/badge';
	import dayjs from 'dayjs';
	import TimeGridEvent from '$lib/components/TimeGridEvent.svelte';
	import WorkshopModalWrapper from './workshop-event-modal.svelte';
	import type { Workshop, WorkshopCalendarEvent } from '$lib/types';
	// TODO: update via event service
	let { workshops = [], onInterestToggle, userId, isLoading = false }: {
		workshops: Workshop[],
		onInterestToggle: (workshopId: string, isInterested: boolean) => void;
		userId: string;
		isLoading: boolean;
	} = $props();

	const eventService = $state(createEventsServicePlugin());

	// Convert workshops to Schedule-X events format using $derived
	const events: WorkshopCalendarEvent[] = $derived(workshops.map(workshop => ({
		id: workshop.id,
		title: workshop.title,
		start: dayjs(workshop.start_date).format('YYYY-MM-DD HH:mm'),
		end: dayjs(workshop.end_date).format('YYYY-MM-DD HH:mm'),
		description: workshop.description,
		location: workshop.location,
		calendarId: 'workshops',
		// Store the full workshop data for the modal
		workshop: workshop,
		isInterested: workshop.user_interest.map(i => i.user_id).includes(userId),
		isLoading,
		onInterestToggle,
		userId
	})));

	const calendarApp = $state(createCalendar({
		theme: 'shadcn',
		views: [
			createViewMonthGrid(),
			createViewWeek()
		],
		events,
		defaultView: 'monthGrid',
		plugins: [eventService, createScrollControllerPlugin({
			initialScroll: '7:50'
		}), createEventModalPlugin()],
		calendars: {
			workshops: {
				colorName: 'workshops',
				lightColors: {
					main: '#3b82f6',
					container: '#dbeafe',
					onContainer: '#1e40af'
				},
				darkColors: {
					main: '#60a5fa',
					container: '#1e3a8a',
					onContainer: '#dbeafe'
				}
			}
		}
	}));
</script>

<div class="workshop-calendar-container">
	<ScheduleXCalendar
		{calendarApp}
		monthGridEvent={TimeGridEvent}
		eventModal={WorkshopModalWrapper}
	/>

	<!-- Legend -->
	<div class="flex items-center gap-4 mt-4 text-sm">
		<div class="flex items-center gap-2">
			<div class="w-4 h-4 bg-blue-500 rounded"></div>
			<span>Planned Workshops</span>
		</div>
		<div class="flex items-center gap-2">
			<Badge variant="outline" class="text-xs">✓</Badge>
			<span>You're interested</span>
		</div>
	</div>
</div>

<style>
    .workshop-calendar-container {
        height: 10svh;
        width: 100%;
    }
</style>
