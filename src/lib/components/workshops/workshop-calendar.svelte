<script lang="ts">
/* eslint-disable @typescript-eslint/no-explicit-any */
import { Calendar, DayGrid, TimeGrid, Interaction } from "@event-calendar/core";
import "@event-calendar/core/index.css";
import * as Dialog from "$lib/components/ui/dialog";
import dayjs from "dayjs";
import WorkshopEventModal from "./workshop-event-modal.svelte";
import type {
	ClubActivityWithRegistrations,
	WorkshopCalendarEvent,
} from "$lib/types";

// Event Calendar types
interface CalendarEvent {
	id: string;
	title: string;
	start: string;
	end: string;
	backgroundColor?: string;
	textColor?: string;
	extendedProps?: {
		workshop: ClubActivityWithRegistrations;
		description?: string;
		location?: string;
		interestCount: number;
		registrationCount: number;
		isInterested: boolean;
	};
}

interface MoreLinkInfo {
	num: number;
}

let {
	workshops = [],
	userId,
	isLoading = false,
	handleEdit,
	onInterestToggle,
}: {
	workshops: ClubActivityWithRegistrations[];
	userId?: string;
	isLoading: boolean;
	handleEdit?: (workshop: ClubActivityWithRegistrations) => void;
	onInterestToggle?: (workshopId: string) => void;
} = $props();

let selectedEvent: WorkshopCalendarEvent | null = $state(null);
let dialogOpen = $state(false);

// Convert workshops to EventCalendar events format with status-based colors
const events: CalendarEvent[] = $derived(
	workshops.map((workshop) => {
		const getStatusColors = (status: string) => {
			switch (status) {
				case "planned":
					return {
						backgroundColor: "hsl(var(--primary))",
						textColor: "hsl(var(--primary-foreground))",
					};
				case "published":
					return {
						backgroundColor: "hsl(142 76% 36%)", // green-600
						textColor: "hsl(0 0% 100%)", // white
					};
				case "cancelled":
					return {
						backgroundColor: "hsl(var(--destructive))",
						textColor: "hsl(var(--destructive-foreground))",
					};
				default:
					return {
						backgroundColor: "hsl(var(--muted))",
						textColor: "hsl(var(--muted-foreground))",
					};
			}
		};

		const colors = getStatusColors(workshop.status || "planned");

		return {
			id: workshop.id,
			title: workshop.title,
			start: dayjs(workshop.start_date).format("YYYY-MM-DD HH:mm"),
			end: dayjs(workshop.end_date).format("YYYY-MM-DD HH:mm"),
			backgroundColor: colors.backgroundColor,
			textColor: colors.textColor,
			extendedProps: {
				workshop: workshop,
				description: workshop.description || undefined,
				location: workshop.location,
				interestCount: workshop.interest_count?.[0]?.interest_count || 0,
				registrationCount: workshop?.user_registrations?.length || 0,
				isInterested: (workshop.user_interest?.length ?? 0) > 0,
			},
		};
	}),
);
// Function to handle event click and show dialog
const handleEventClick = (info: {
	event: {
		extendedProps?: {
			workshop?: ClubActivityWithRegistrations;
			isInterested?: boolean;
		};
	};
}) => {
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
		userId: userId || "",
		handleEdit: handleEdit,
	};

	dialogOpen = true;
};

// Calendar options with shadcn theming
const options = $derived({
	view: "dayGridMonth",
	events: events,
	headerToolbar: {
		start: "prev,next today",
		center: "title",
		end: "dayGridMonth,timeGridWeek,timeGridDay",
	},
	height: "600px",
	eventClick: handleEventClick,
	eventContent: (info: any) => {
		const workshop: ClubActivityWithRegistrations =
			info.event.extendedProps?.workshop;
		const interestCount = info.event.extendedProps?.interestCount || 0;
		const registrationCount = info.event.extendedProps?.registrationCount || 0;

		if (!workshop) {
			return {
				html: `<div class="workshop-event p-1">${info.event.title}</div>`,
			};
		}

		return {
			html: `
					<div class="workshop-event p-2 cursor-pointer hover:opacity-90 transition-opacity">
						<div class="workshop-event-title font-medium text-sm flex items-center gap-1">
							<span class="truncate">${workshop.title}</span>
						</div>
						<div class="workshop-event-info text-xs opacity-90 mt-1">
							<div class="flex items-center justify-between">
								<span>${workshop.status === "planned" ? `${interestCount} interested` : `${registrationCount} registered`}</span>
								<span class="text-xs opacity-75">${dayjs(workshop.start_date).format("HH:mm")}</span>
							</div>
						</div>
					</div>
				`,
		};
	},
	dayMaxEvents: false, // Show all events without "+X more" limit
	moreLinkContent: (arg: MoreLinkInfo): string => `+${arg.num} more`,
	selectable: false,
	editable: false,
	// Custom theme to match shadcn design system
	theme: (defaultTheme: Record<string, string | string[]>) => ({
		...defaultTheme,
		calendar: "ec bg-card text-card-foreground border border-border rounded-lg",
		header: "ec-header bg-card border-b border-border",
		toolbar: "ec-toolbar flex items-center justify-between p-4",
		button:
			"ec-button inline-flex items-center justify-center rounded-md text-sm font-medium ring-offset-background transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 border border-input bg-background hover:bg-accent hover:text-accent-foreground h-10 px-4 py-2",
		buttonGroup: "ec-button-group flex",
		active: "ec-active bg-primary text-primary-foreground hover:bg-primary/90",
		title: "ec-title text-lg font-semibold text-foreground",
		body: "ec-body bg-card",
		dayHead:
			"ec-day-head bg-muted/50 border-b border-border text-muted-foreground font-medium text-sm p-2",
		day: "ec-day border-r border-b border-border hover:bg-muted/50 transition-colors",
		today: "ec-today bg-accent/20",
		otherMonth: "ec-other-month text-muted-foreground/50",
		event:
			"ec-event bg-primary text-primary-foreground rounded-sm border border-primary/20 shadow-sm",
		eventBody: "ec-event-body p-1",
		eventTitle: "ec-event-title font-medium text-xs",
		eventTime: "ec-event-time text-xs opacity-90",
		popup:
			"ec-popup bg-popover text-popover-foreground border border-border rounded-lg shadow-lg",
		nowIndicator: "ec-now-indicator bg-destructive",
	}),
});
</script>

<div class="workshop-calendar-container relative">
    <div>
        <Calendar plugins={[DayGrid, TimeGrid, Interaction]} {options}/>
    </div>

    <!-- Legend -->
    <div class="flex items-center gap-6 mt-4 text-sm text-muted-foreground">
        <div class="flex items-center gap-2">
            <div class="w-4 h-4 bg-primary rounded-sm border border-primary/20"></div>
            <span>Planned</span>
        </div>
        <div class="flex items-center gap-2">
            <div class="w-4 h-4 bg-green-500 rounded-sm border border-green-500/20"></div>
            <span>Published</span>
        </div>
        <div class="flex items-center gap-2">
            <div class="w-4 h-4 bg-destructive rounded-sm border border-destructive/20"></div>
            <span>Cancelled</span>
        </div>
    </div>
</div>

<!-- Workshop Event Dialog -->
<Dialog.Root bind:open={dialogOpen}>
    <Dialog.Content class="max-w-lg p-0 gap-0">
        {#if selectedEvent}
            <WorkshopEventModal
                    calendarEvent={selectedEvent}
                    {onInterestToggle}
                    onClose={() => (dialogOpen = false)}
            />
        {/if}
    </Dialog.Content>
</Dialog.Root>

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

    /* Dialog content styling */

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
</style>
