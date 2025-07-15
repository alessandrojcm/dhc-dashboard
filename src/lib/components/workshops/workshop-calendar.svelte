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

	// Convert workshops to EventCalendar events format with shadcn colors
	const events: CalendarEvent[] = $derived(workshops.map(workshop => ({
		id: workshop.id,
		title: workshop.title,
		start: dayjs(workshop.start_date).format('YYYY-MM-DD HH:mm'),
		end: dayjs(workshop.end_date).format('YYYY-MM-DD HH:mm'),
		backgroundColor: 'hsl(var(--primary))',
		textColor: 'hsl(var(--primary-foreground))',
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

	// Calendar options with shadcn theming
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
								${isInterested ? '<span class="text-secondary-foreground bg-secondary px-1 rounded-sm">✓ Interested</span>' : ''}
							</div>
						</div>
					</div>
				`
			};
		},
		dayMaxEvents: true,
		moreLinkContent: (arg: MoreLinkInfo): string => `+${arg.num} more`,
		selectable: false,
		editable: false,
		// Custom theme to match shadcn design system
		theme: (defaultTheme: any) => ({
			...defaultTheme,
			calendar: 'ec bg-card text-card-foreground border border-border rounded-lg',
			header: 'ec-header bg-card border-b border-border',
			toolbar: 'ec-toolbar flex items-center justify-between p-4',
			button: 'ec-button inline-flex items-center justify-center rounded-md text-sm font-medium ring-offset-background transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 border border-input bg-background hover:bg-accent hover:text-accent-foreground h-10 px-4 py-2',
			buttonGroup: 'ec-button-group flex',
			active: 'ec-active bg-primary text-primary-foreground hover:bg-primary/90',
			title: 'ec-title text-lg font-semibold text-foreground',
			body: 'ec-body bg-card',
			dayHead: 'ec-day-head bg-muted/50 border-b border-border text-muted-foreground font-medium text-sm p-2',
			day: 'ec-day border-r border-b border-border hover:bg-muted/50 transition-colors',
			today: 'ec-today bg-accent/20',
			otherMonth: 'ec-other-month text-muted-foreground/50',
			event: 'ec-event bg-primary text-primary-foreground rounded-sm border border-primary/20 shadow-sm',
			eventBody: 'ec-event-body p-1',
			eventTitle: 'ec-event-title font-medium text-xs',
			eventTime: 'ec-event-time text-xs opacity-90',
			popup: 'ec-popup bg-popover text-popover-foreground border border-border rounded-lg shadow-lg',
			nowIndicator: 'ec-now-indicator bg-destructive'
		})
	});
	$inspect(selectedEvent)
</script>

<div class="workshop-calendar-container relative">
	<div bind:this={calendarElement}>
		<Calendar plugins={[DayGrid, TimeGrid, Interaction]} {options} />
	</div>
	
	<!-- Legend -->
	<div class="flex items-center gap-4 mt-4 text-sm text-muted-foreground">
		<div class="flex items-center gap-2">
			<div class="w-4 h-4 bg-primary rounded-sm border border-primary/20"></div>
			<span>Planned Workshops</span>
		</div>
	</div>
</div>

<!-- Workshop Event Popover using native Popover API -->
<div
	bind:this={popoverElement}
	popover="auto"
	class="workshop-popover w-96 p-0 m-0"
	style="position: absolute; left: {popoverPosition.x - 192}px; top: {popoverPosition.y}px; transform: translateY(-100%);"
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
	
	/* Ensure popover inherits theme colors */
	:global([popover]) {
		color: hsl(var(--popover-foreground));
		background-color: hsl(var(--popover));
	}
	
	:global([popover] *) {
		color: inherit;
	}
	
	/* Override default event calendar styles with shadcn theme */
	:global(.ec) {
		font-family: inherit;
	}
	
	/* Ensure buttons use shadcn styling */
	:global(.ec-button) {
		transition: all 0.2s ease-in-out;
	}
	
	:global(.ec-button:hover) {
		background-color: hsl(var(--accent));
		color: hsl(var(--accent-foreground));
	}
	
	:global(.ec-button.ec-active) {
		background-color: hsl(var(--primary));
		color: hsl(var(--primary-foreground));
	}
	
	/* Style the more link */
	:global(.ec .ec-more-link) {
		color: hsl(var(--primary));
		text-decoration: none;
		font-size: 0.75rem;
		padding: 0.25rem;
		border-radius: calc(var(--radius) - 2px);
		transition: all 0.2s ease-in-out;
	}
	
	:global(.ec .ec-more-link:hover) {
		background-color: hsl(var(--accent));
		color: hsl(var(--accent-foreground));
	}
	
	/* Proper popover styling */
	:global(.workshop-popover) {
		background-color: var(--color-white);
		color: hsl(var(--popover-foreground));
		border: 1px solid hsl(var(--border));
		border-radius: calc(var(--radius) + 2px);
		box-shadow: 0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1);
	}
</style>

