<script lang="ts">
	import { Calendar, DayGrid, TimeGrid, Interaction } from '@event-calendar/core';
	import '@event-calendar/core/index.css';
	import dayjs from 'dayjs';
	import WorkshopEventModal from './workshop-event-modal.svelte';
	import type { Workshop, WorkshopCalendarEvent } from '$lib/types';

	// Event Calendar types
	interface CalendarEvent {
		id: string;
		title: string;
		start: string;
		end: string;
		backgroundColor?: string;
		textColor?: string;
		extendedProps?: {
			workshop: Workshop;
			description?: string;
			location?: string;
			interestCount: number;
			isInterested: boolean;
		};
	}

	interface EventClickInfo {
		event: {
			id: string;
			title: string;
			extendedProps: CalendarEvent['extendedProps'];
		};
		el: HTMLElement;
	}

	interface EventContentInfo {
		event: {
			title: string;
			extendedProps: CalendarEvent['extendedProps'];
		};
	}

	interface EventContentResult {
		html: string;
	}

	interface MoreLinkInfo {
		num: number;
	}

	let { workshops = [], userId, isLoading = false, handleEdit, handleDelete, handlePublish, handleCancel, onInterestToggle }: {
		workshops: Workshop[],
		userId?: string;
		isLoading: boolean;
		handleEdit?: (workshop: Workshop) => void;
		handleDelete?: (workshop: Workshop) => void;
		handlePublish?: (workshop: Workshop) => void;
		handleCancel?: (workshop: Workshop) => void;
		onInterestToggle?: (workshopId: string) => void;
	} = $props();

	let calendarElement: HTMLElement;
	let selectedEvent: WorkshopCalendarEvent | null = $state(null);
	let popoverElement: HTMLElement | undefined = $state();
	let popoverPosition = $state({ x: 0, y: 0 });

	// Convert workshops to EventCalendar events format
	const events: CalendarEvent[] = $derived(workshops.map(workshop => ({
		id: workshop.id,
		title: workshop.title,
		start: dayjs(workshop.start_date).format('YYYY-MM-DD HH:mm'),
		end: dayjs(workshop.end_date).format('YYYY-MM-DD HH:mm'),
		backgroundColor: '#3b82f6',
		textColor: '#ffffff',
		extendedProps: {
			workshop: workshop,
			description: workshop.description,
			location: workshop.location,
			interestCount: workshop.interest_count?.[0]?.interest_count || 0,
			isInterested: workshop.user_interest && workshop.user_interest.length > 0
		}
	})));
	// Function to handle event click and show native popover
	const handleEventClick = (info: EventClickInfo) => {
		const workshop = info.event.extendedProps?.workshop;
		const isInterested = info.event.extendedProps?.isInterested;
		
		if (!workshop) return;
		
		selectedEvent = {
			id: workshop.id,
			title: workshop.title,
			start: workshop.start_date,
			end: workshop.end_date,
			workshop: workshop,
			isInterested: isInterested || false,
			isLoading: isLoading,
			userId: userId || '',
			handleEdit: handleEdit || (() => {}),
			handleDelete: handleDelete || (() => {}),
			handlePublish: handlePublish || (() => {}),
			handleCancel: handleCancel || (() => {})
		};
		
		// Calculate position for the popover
		const clickedElement = info.el;
		if (clickedElement && calendarElement) {
			const rect = clickedElement.getBoundingClientRect();
			const calendarRect = calendarElement.getBoundingClientRect();
			
			// Position relative to the calendar container
			let x = rect.left - calendarRect.left + rect.width / 2;
			let y = rect.top - calendarRect.top;
			
			// Ensure popover doesn't go off screen
			const popoverWidth = 384; // w-96 = 384px
			if (x - popoverWidth / 2 < 0) {
				x = popoverWidth / 2;
			}
			if (x + popoverWidth / 2 > calendarRect.width) {
				x = calendarRect.width - popoverWidth / 2;
			}
			
			// Position above the event, or below if no space
			if (y > 200) {
				y = y - 10; // Above with some margin
			} else {
				y = rect.bottom - calendarRect.top + 10; // Below with margin
			}
			
			popoverPosition = { x, y };
		}
		
		// Show the native popover
		if (popoverElement) {
			popoverElement.showPopover();
		}
	};

	// Calendar options
	const options = $derived({
		view: 'dayGridMonth',
		events: events,
		headerToolbar: {
			start: 'prev,next today',
			center: 'title',
			end: 'dayGridMonth,timeGridWeek,timeGridDay'
		},
		height: '600px',
		eventClick: handleEventClick,
		eventContent: (info: EventContentInfo): EventContentResult => {
			const workshop = info.event.extendedProps?.workshop;
			const interestCount = info.event.extendedProps?.interestCount || 0;
			const isInterested = info.event.extendedProps?.isInterested || false;
			
			if (!workshop) {
				return { html: `<div class="workshop-event p-1">${info.event.title}</div>` };
			}
			
			return {
				html: `
					<div class="workshop-event p-1">
						<div class="workshop-event-title font-medium text-sm">${workshop.title}</div>
						<div class="workshop-event-info text-xs opacity-80 mt-1">
							<div class="flex items-center justify-between">
								<span>${interestCount} interested</span>
								${isInterested ? '<span class="text-green-400">✓ Interested</span>' : ''}
							</div>
						</div>
					</div>
				`
			};
		},
		dayMaxEvents: true,
		moreLinkContent: (arg: MoreLinkInfo): string => `+${arg.num} more`,
		selectable: false,
		editable: false
	});
	$inspect(selectedEvent)
</script>

<div class="workshop-calendar-container relative">
	<div bind:this={calendarElement}>
		<Calendar plugins={[DayGrid, TimeGrid, Interaction]} {options} />
	</div>
	
	<!-- Legend -->
	<div class="flex items-center gap-4 mt-4 text-sm">
		<div class="flex items-center gap-2">
			<div class="w-4 h-4 bg-blue-500 rounded"></div>
			<span>Planned Workshops</span>
		</div>
	</div>
</div>

<!-- Workshop Event Popover using native Popover API -->
<div
	bind:this={popoverElement}
	popover="auto"
	class="w-96 bg-white text-gray-900 border border-gray-200 rounded-lg shadow-lg p-0 m-0"
	style="position: absolute; left: {popoverPosition.x - 192}px; top: {popoverPosition.y}px; transform: translateY(-100%); color: rgb(17 24 39);"
>
	{#if selectedEvent}
		<WorkshopEventModal 
			calendarEvent={selectedEvent} 
			{onInterestToggle} 
			onClose={() => popoverElement?.hidePopover()}
		/>
	{/if}
</div>

<style>
	.workshop-calendar-container {
		width: 100%;
	}
	
	/* Custom event styling */
	:global(.workshop-event) {
		width: 100%;
		height: 100%;
	}
	
	:global(.workshop-event-title) {
		line-height: 1.2;
	}
	
	:global(.workshop-event-info) {
		line-height: 1.1;
	}
	
	/* Ensure popover text is visible */
	:global([popover]) {
		color: rgb(17 24 39);
	}
	
	:global([popover] *) {
		color: inherit;
	}
	
	:global([popover] .text-muted-foreground) {
		color: var(--color-white) !important;
	}
</style>

