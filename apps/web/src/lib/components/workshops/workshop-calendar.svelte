<script lang="ts">
import { Calendar, DayGrid, Interaction } from "@event-calendar/core";
import "@event-calendar/core/index.css";
import * as Dialog from "$lib/components/ui/dialog";
import dayjs from "dayjs";
import WorkshopEventModal from "./workshop-event-modal.svelte";
import type { WorkshopCalendarEvent } from "$lib/types";
import type { WorkshopCalendarItem } from "@dhc/api-client";

interface CalendarEvent {
	id: string;
	title: string;
	start: string;
	end: string;
	extendedProps?: {
		workshop: WorkshopCalendarItem;
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

function escapeHtml(value: string) {
	return value.replace(/[&<>"']/g, (character) => {
		switch (character) {
			case "&":
				return "&amp;";
			case "<":
				return "&lt;";
			case ">":
				return "&gt;";
			case '"':
				return "&quot;";
			case "'":
				return "&#039;";
			default:
				return character;
		}
	});
}

function getStatusLabel(status: WorkshopCalendarItem["status"]) {
	return `${status.charAt(0).toUpperCase()}${status.slice(1)}`;
}

let {
	workshops = [],
	userId,
	isLoading = false,
	handleEdit,
	onInterestToggle,
}: {
	workshops: WorkshopCalendarItem[];
	userId?: string;
	isLoading: boolean;
	handleEdit?: (workshop: WorkshopCalendarItem) => void;
	onInterestToggle?: (workshopId: string) => void;
} = $props();

let selectedEvent: WorkshopCalendarEvent | null = $state(null);
let dialogOpen = $state(false);

const events: CalendarEvent[] = $derived(
	workshops.map((workshop) => ({
		id: workshop.id,
		title: workshop.title,
		start: dayjs(workshop.startDate).format("YYYY-MM-DD HH:mm"),
		end: dayjs(workshop.endDate).format("YYYY-MM-DD HH:mm"),
		extendedProps: {
			workshop,
			description: workshop.description || undefined,
			location: workshop.location || undefined,
			interestCount: workshop.interestCount,
			registrationCount: workshop.registrationCount,
			isInterested: false,
		},
	})),
);

const handleEventClick = (info: {
	event: {
		extendedProps?: {
			workshop?: WorkshopCalendarItem;
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
		start: workshop.startDate,
		end: workshop.endDate,
		workshop,
		isInterested: isInterested || false,
		isLoading,
		userId: userId || "",
		handleEdit,
	};

	dialogOpen = true;
};

const options = $derived({
	view: "dayGridMonth",
	events,
	headerToolbar: {
		start: "title",
		center: "",
		end: "today prev,next",
	},
	buttonText: {
		today: "Today",
	},
	height: "auto",
	eventClick: handleEventClick,
	eventContent: (info: Calendar.EventContentInfo) => {
		const workshop = workshops.find(
			(item) => item.id === String(info.event.id),
		);
		const interestCount = Number(info.event.extendedProps?.interestCount) || 0;
		const registrationCount =
			Number(info.event.extendedProps?.registrationCount) || 0;

		if (!workshop) {
			const eventTitle = escapeHtml(String(info.event.title || "Workshop"));

			return {
				html: `<div class="workshop-event workshop-event--finished"><div class="workshop-event-title">${eventTitle}</div></div>`,
			};
		}

		const title = escapeHtml(workshop.title);
		const statusLabel = getStatusLabel(workshop.status);
		const attendanceLabel =
			workshop.status === "planned"
				? `${interestCount} interested`
				: `${registrationCount} registered`;
		const publicMarker = workshop.isPublic
			? '<span class="workshop-public-marker" aria-label="Public workshop">Public</span>'
			: "";

		return {
			html: `
				<div class="workshop-event workshop-event--${workshop.status}" title="${title}">
					<div class="workshop-event-meta">
						<span class="workshop-event-status">
							<span class="workshop-event-status-dot" aria-hidden="true"></span>
							${statusLabel}
						</span>
						<time>${dayjs(workshop.startDate).format("HH:mm")}</time>
					</div>
					<div class="workshop-event-title">${title}</div>
					<div class="workshop-event-footer">
						<span>${attendanceLabel}</span>
						${publicMarker}
					</div>
				</div>
			`,
		};
	},
	dayMaxEvents: true,
	moreLinkContent: (arg: MoreLinkInfo): string => `+${arg.num} more`,
	selectable: false,
	editable: false,
	theme: (defaultTheme: Record<string, string | string[]>) => ({
		...defaultTheme,
		calendar: "ec workshop-calendar",
		header: "ec-header workshop-calendar-weekdays",
		toolbar: "ec-toolbar workshop-calendar-toolbar",
		button: "ec-button workshop-calendar-control",
		buttonGroup: "ec-button-group workshop-calendar-control-group",
		active: "ec-active",
		title: "ec-title workshop-calendar-title",
		body: "ec-body workshop-calendar-body",
		dayHead: "ec-day-head workshop-calendar-day-number",
		day: "ec-day workshop-calendar-day",
		today: "ec-today workshop-calendar-today",
		otherMonth: "ec-other-month workshop-calendar-other-month",
		event: "ec-event workshop-calendar-event",
		eventBody: "ec-event-body workshop-calendar-event-body",
		eventTitle: "ec-event-title",
		eventTime: "ec-event-time",
		popup: "ec-popup workshop-calendar-popup",
		nowIndicator: "ec-now-indicator bg-destructive",
	}),
});
</script>

<div
	class="workshop-calendar-container overflow-hidden rounded-2xl border border-border/80 bg-card shadow-sm"
>
	{#if isLoading}
		<div class="p-5" role="status" aria-label="Loading workshop calendar">
			<div class="flex items-center justify-between gap-4 border-b pb-5">
				<div class="h-8 w-44 animate-pulse rounded-lg bg-muted"></div>
				<div class="h-11 w-44 animate-pulse rounded-lg bg-muted"></div>
			</div>
			<div
				class="mt-4 grid grid-cols-7 gap-px overflow-hidden rounded-xl bg-border"
			>
				{#each { length: 42 } as _, index (index)}
					<div class="h-24 animate-pulse bg-muted/50"></div>
				{/each}
			</div>
			<span class="sr-only">Loading calendar</span>
		</div>
	{:else}
		<Calendar plugins={[DayGrid, Interaction]} {options} />
	{/if}

	<div
		class="flex flex-col gap-3 border-t border-border/70 bg-muted/20 px-5 py-4 xl:flex-row xl:items-center xl:justify-between"
	>
		<p class="text-sm font-medium text-foreground">
			<span class="font-bold tabular-nums">{workshops.length}</span>
			{workshops.length === 1 ? "workshop" : "workshops"} on this calendar
		</p>
		<div
			class="flex flex-wrap items-center gap-x-5 gap-y-2 text-xs font-semibold text-muted-foreground"
			aria-label="Workshop status key"
		>
			<span class="flex items-center gap-2">
				<span class="h-2.5 w-2.5 rounded-full bg-secondary"></span>
				Planned
			</span>
			<span class="flex items-center gap-2">
				<span class="h-2.5 w-2.5 rounded-full bg-primary"></span>
				Published
			</span>
			<span class="flex items-center gap-2">
				<span class="h-2.5 w-2.5 rounded-full bg-muted-foreground"></span>
				Finished
			</span>
			<span class="flex items-center gap-2">
				<span class="h-2.5 w-2.5 rounded-full bg-destructive"></span>
				Cancelled
			</span>
			<span class="workshop-public-marker">Public</span>
		</div>
	</div>
</div>

<Dialog.Root bind:open={dialogOpen}>
	<Dialog.Content
		class="max-h-[calc(100dvh-2rem)] max-w-2xl gap-0 overflow-hidden p-0 sm:max-w-2xl"
		showCloseButton={false}
	>
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
:global(.workshop-calendar) {
	--ec-bg-color: hsl(var(--card));
	--ec-border-color: hsl(var(--border) / 0.72);
	--ec-button-bg-color: hsl(var(--background));
	--ec-button-border-color: hsl(var(--border));
	--ec-button-text-color: hsl(var(--foreground));
	--ec-today-bg-color: hsl(var(--secondary) / 0.12);
	width: 100%;
	border: 0;
	background: hsl(var(--card));
	color: hsl(var(--foreground));
	font-family: inherit;
}

:global(.workshop-calendar .workshop-calendar-toolbar) {
	display: grid;
	grid-template-columns: minmax(0, 1fr) auto;
	gap: 1rem;
	align-items: center;
	padding: 1.25rem;
	border-bottom: 1px solid hsl(var(--border) / 0.72);
	background:
		linear-gradient(90deg, hsl(var(--primary) / 0.08), transparent 58%),
		hsl(var(--card));
}

:global(.workshop-calendar .ec-center:empty) {
	display: none;
}

:global(.workshop-calendar .ec-end) {
	display: flex;
	align-items: center;
	justify-content: flex-end;
	gap: 0.75rem;
}

:global(.workshop-calendar .workshop-calendar-title) {
	font-family: var(--font-heading), serif;
	font-size: 1.5rem;
	font-weight: 700;
	letter-spacing: -0.02em;
	color: hsl(var(--foreground));
}

:global(.workshop-calendar .workshop-calendar-control-group) {
	display: flex;
	gap: 0.5rem;
}

:global(.workshop-calendar .workshop-calendar-control) {
	display: inline-flex;
	min-width: 2.75rem;
	min-height: 2.75rem;
	align-items: center;
	justify-content: center;
	border: 1px solid hsl(var(--border));
	border-radius: 0.75rem;
	background: hsl(var(--background));
	padding: 0.625rem 0.875rem;
	color: hsl(var(--foreground));
	font-size: 0.875rem;
	font-weight: 700;
	box-shadow: 0 1px 2px rgb(0 0 0 / 5%);
	cursor: pointer;
	transition:
		border-color 180ms ease,
		background-color 180ms ease,
		color 180ms ease,
		box-shadow 180ms ease;
}

:global(.workshop-calendar .workshop-calendar-control:hover) {
	border-color: hsl(var(--primary) / 0.45);
	background: hsl(var(--primary) / 0.08);
	color: hsl(var(--primary));
}

:global(.workshop-calendar .workshop-calendar-control:focus-visible) {
	outline: 2px solid hsl(var(--ring));
	outline-offset: 2px;
}

:global(.workshop-calendar .workshop-calendar-weekdays) {
	border-bottom: 1px solid hsl(var(--border) / 0.72);
	background: hsl(var(--muted) / 0.45);
}

:global(.workshop-calendar .workshop-calendar-weekdays .workshop-calendar-day) {
	display: flex;
	min-height: 2.75rem;
	align-items: center;
	justify-content: center;
	border-right: 1px solid hsl(var(--border) / 0.72);
	color: hsl(var(--muted-foreground));
	font-size: 0.6875rem;
	font-weight: 800;
	letter-spacing: 0.12em;
	text-transform: uppercase;
}

:global(.workshop-calendar .workshop-calendar-body .workshop-calendar-day) {
	min-height: 7.5rem;
	border-right: 1px solid hsl(var(--border) / 0.72);
	border-bottom: 1px solid hsl(var(--border) / 0.72);
	background: hsl(var(--card));
	transition: background-color 180ms ease;
}

:global(
	.workshop-calendar .workshop-calendar-body .workshop-calendar-day:hover
) {
	background: hsl(var(--muted) / 0.2);
}

:global(
	.workshop-calendar .workshop-calendar-body .workshop-calendar-day.ec-sat,
	.workshop-calendar .workshop-calendar-body .workshop-calendar-day.ec-sun
) {
	background: hsl(var(--muted) / 0.12);
}

:global(.workshop-calendar .workshop-calendar-day-number) {
	display: flex;
	justify-content: flex-end;
	border: 0;
	background: transparent;
	padding: 0.625rem 0.75rem 0.375rem;
	color: hsl(var(--foreground));
	font-size: 0.75rem;
	font-weight: 700;
	font-variant-numeric: tabular-nums;
}

:global(.workshop-calendar .workshop-calendar-day-number time) {
	display: inline-flex;
	width: 1.75rem;
	height: 1.75rem;
	align-items: center;
	justify-content: center;
	border-radius: 9999px;
}

:global(
	.workshop-calendar
		.workshop-calendar-today
		.workshop-calendar-day
		.workshop-calendar-day-number
		time
) {
	background: hsl(var(--primary));
	color: hsl(var(--primary-foreground));
	box-shadow: 0 0 0 3px hsl(var(--secondary) / 0.35);
}

:global(
	.workshop-calendar .workshop-calendar-body .workshop-calendar-other-month
) {
	background: hsl(var(--muted) / 0.28);
}

:global(
	.workshop-calendar
		.workshop-calendar-other-month
		.workshop-calendar-day-number
) {
	color: hsl(var(--muted-foreground) / 0.48);
}

:global(.workshop-calendar .workshop-calendar-event) {
	margin: 0 0.375rem 0.375rem;
	border: 0 !important;
	background: transparent !important;
	color: inherit !important;
	box-shadow: none !important;
	cursor: pointer;
}

:global(.workshop-calendar .workshop-calendar-event-body) {
	padding: 0;
}

:global(.workshop-event) {
	width: 100%;
	min-width: 0;
	border: 1px solid hsl(var(--border) / 0.78);
	border-left-width: 3px;
	border-radius: 0.625rem;
	background: hsl(var(--card));
	padding: 0.5rem 0.625rem;
	color: hsl(var(--foreground));
	box-shadow: 0 1px 2px rgb(0 0 0 / 5%);
	transition:
		border-color 180ms ease,
		box-shadow 180ms ease,
		background-color 180ms ease;
}

:global(.workshop-calendar-event:hover .workshop-event) {
	border-color: hsl(var(--primary) / 0.5);
	background: hsl(var(--primary) / 0.04);
	box-shadow: 0 4px 10px rgb(0 0 0 / 8%);
}

:global(.workshop-calendar-event:focus-visible) {
	outline: 2px solid hsl(var(--ring));
	outline-offset: 1px;
}

:global(.workshop-event--planned) {
	border-left-color: hsl(var(--secondary));
	background: hsl(var(--secondary) / 0.08);
}

:global(.workshop-event--published) {
	border-left-color: hsl(var(--primary));
	background: hsl(var(--primary) / 0.055);
}

:global(.workshop-event--finished) {
	border-left-color: hsl(var(--muted-foreground));
	background: hsl(var(--muted) / 0.28);
}

:global(.workshop-event--cancelled) {
	border-left-color: hsl(var(--destructive));
	background: hsl(var(--destructive) / 0.055);
}

:global(.workshop-event-meta),
:global(.workshop-event-footer) {
	display: flex;
	min-width: 0;
	align-items: center;
	justify-content: space-between;
	gap: 0.375rem;
}

:global(.workshop-event-meta) {
	color: hsl(var(--muted-foreground));
	font-size: 0.625rem;
	font-weight: 800;
	letter-spacing: 0.06em;
	line-height: 1.2;
	text-transform: uppercase;
}

:global(.workshop-event-meta time) {
	font-variant-numeric: tabular-nums;
	letter-spacing: 0;
}

:global(.workshop-event-status) {
	display: inline-flex;
	min-width: 0;
	align-items: center;
	gap: 0.3rem;
}

:global(.workshop-event-status-dot) {
	width: 0.45rem;
	height: 0.45rem;
	flex: none;
	border-radius: 9999px;
	background: hsl(var(--muted-foreground));
}

:global(.workshop-event--planned .workshop-event-status-dot) {
	background: hsl(var(--secondary));
}

:global(.workshop-event--published .workshop-event-status-dot) {
	background: hsl(var(--primary));
}

:global(.workshop-event--cancelled .workshop-event-status-dot) {
	background: hsl(var(--destructive));
}

:global(.workshop-event-title) {
	display: -webkit-box;
	overflow: hidden;
	line-clamp: 2;
	-webkit-box-orient: vertical;
	-webkit-line-clamp: 2;
	margin-top: 0.3rem;
	font-size: 0.75rem;
	font-weight: 800;
	line-height: 1.25;
}

:global(.workshop-event-footer) {
	margin-top: 0.4rem;
	color: hsl(var(--muted-foreground));
	font-size: 0.625rem;
	font-weight: 600;
	line-height: 1.2;
}

:global(.workshop-public-marker) {
	display: inline-flex;
	flex: none;
	align-items: center;
	border: 1px solid currentColor;
	border-radius: 9999px;
	padding: 0.1rem 0.3rem;
	font-size: 0.5625rem;
	font-weight: 800;
	line-height: 1;
	letter-spacing: 0.04em;
	text-transform: uppercase;
}

:global(.workshop-calendar .ec-more-link) {
	display: inline-flex;
	min-height: 2rem;
	align-items: center;
	margin: 0 0.375rem 0.375rem;
	border-radius: 0.5rem;
	padding: 0.25rem 0.5rem;
	color: hsl(var(--primary));
	font-size: 0.6875rem;
	font-weight: 800;
	text-decoration: none;
	transition:
		background-color 180ms ease,
		color 180ms ease;
}

:global(.workshop-calendar .ec-more-link:hover) {
	background: hsl(var(--primary) / 0.1);
}

:global(.workshop-calendar .ec-more-link:focus-visible) {
	outline: 2px solid hsl(var(--ring));
	outline-offset: 1px;
}

:global(.workshop-calendar .workshop-calendar-popup) {
	border: 1px solid hsl(var(--border));
	border-radius: 1rem;
	background: hsl(var(--popover));
	color: hsl(var(--popover-foreground));
	box-shadow: 0 14px 30px rgb(0 0 0 / 14%);
}

@media (max-width: 900px) {
	:global(.workshop-calendar .workshop-calendar-toolbar) {
		grid-template-columns: 1fr;
	}

	:global(.workshop-calendar .ec-end) {
		justify-content: space-between;
	}

	:global(.workshop-event-footer) {
		display: none;
	}
}

@media (prefers-reduced-motion: reduce) {
	:global(.workshop-calendar *),
	:global(.workshop-calendar *::before),
	:global(.workshop-calendar *::after) {
		scroll-behavior: auto !important;
		transition-duration: 0.01ms !important;
	}
}
</style>
