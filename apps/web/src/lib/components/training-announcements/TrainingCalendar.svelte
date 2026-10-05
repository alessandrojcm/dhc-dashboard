<!--
	The Training Announcements calendar (ALE-332): every Announcement
	Occurrence and Holiday Announcement in the visible range, read from the
	`window` read model across all announcements.

	- Month/Week views over `@event-calendar/core`, chrome from the shared
	  `$lib/components/calendar/dhc-calendar.css`, chips styled here. The view
	  switch is owned by Svelte state and remounts the calendar (`{#key}`):
	  pushing `view` through the reactive options leaves event-calendar's root
	  view classes stale, so the next plugin renders without its CSS.
	- Events are whole days (`start`/`end` as `YYYY-MM-DD`, which event-calendar
	  reads as all-day): a post is an instant on a date, never a timed span.
	- `datesSet` only writes the range when the window actually moved — a fresh
	  object every call re-renders the calendar forever.
	- Chip content reads the `window` items only, never selection or other UI
	  state, so interacting with the page cannot rebuild every chip.
	- A range starting before the 400-day retention horizon is refused with an
	  explanation; the API is never called with an invalid `from`.

	Clicking a chip reports the item to the rail (which selects its
	announcement and opens the occurrence inspector on the payload).
-->
<script lang="ts">
import {
	trainingAnnouncementOccurrencesWindowOptions,
	type TrainingAnnouncementOccurrence,
} from "@dhc/api-client";
import { createQuery } from "@tanstack/svelte-query";
import { Calendar, DayGrid, Interaction, List } from "@event-calendar/core";
import "@event-calendar/core/index.css";
import "$lib/components/calendar/dhc-calendar.css";
import "./occurrence-tone.css";
import { Alert, AlertDescription, AlertTitle } from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";
import { ToggleGroup, ToggleGroupItem } from "$lib/components/ui/toggle-group";
import { TriangleAlert } from "@lucide/svelte";
import { apiErrorMessage } from "$lib/api-error";
import { announcementDateLabel } from "$lib/training-announcements/announcement";
import {
	occurrenceKey,
	occurrenceStatus,
	occurrenceTitle,
} from "$lib/training-announcements/status";
import {
	datesSetWindow,
	retentionHorizon,
	windowAllowed,
	type WindowRange,
} from "$lib/training-announcements/window";

let {
	today,
	initialDate = today,
	onSelectItem,
}: {
	/** Europe/Dublin today as `YYYY-MM-DD`, from the page load. */
	today: string;
	/** First date the calendar opens on; the toolbar owns it afterwards. */
	initialDate?: string;
	onSelectItem?: (item: TrainingAnnouncementOccurrence) => void;
} = $props();

let view = $state<"dayGridMonth" | "listWeek">("dayGridMonth");
let anchor = $state(initialDate);
let range = $state<WindowRange | null>(null);

const horizon = $derived(retentionHorizon(today));
const refused = $derived(range !== null && !windowAllowed(range.from, horizon));

const occurrences = createQuery(() => ({
	...trainingAnnouncementOccurrencesWindowOptions({
		query: { from: range?.from ?? today, to: range?.to ?? today },
	}),
	enabled: range !== null && windowAllowed(range.from, horizon),
	select: (response) => response.data,
}));

const itemsById = $derived(
	new Map((occurrences.data ?? []).map((item) => [occurrenceKey(item), item])),
);

const events = $derived(
	[...itemsById].map(([id, item]) => ({
		id,
		title: occurrenceTitle(item),
		// Date-only bounds read as all-day whole-day events: a post is an
		// instant on its send date, never a timed span.
		start: item.date,
		end: item.date,
	})),
);

/** Bank-holiday dates in view render as striped days. */
const highlightedDates = $derived([
	...new Set(
		[...itemsById.values()].flatMap((item) =>
			item.holidayDate ? [item.holidayDate] : [],
		),
	),
]);

function escapeHtml(value: string): string {
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

const options = $derived({
	// The view toggle below owns `view`; the calendar toolbar never switches
	// views, it only moves the date.
	view,
	date: anchor,
	events: refused ? [] : events,
	headerToolbar: {
		start: "title",
		center: "",
		end: "today prev,next",
	},
	// Full weekday names would wrap to two lines in a ~48px phone column; the
	// narrow header stays one line. Month cells carry the day number instead.
	dayHeaderFormat: { weekday: "short" as const },
	buttonText: { today: "Today" },
	// Month rows must grow with the shared day-cell minimum height, as in the
	// workshop calendar. A fixed height squeezes rows below their cells and
	// exposes both the row border and the overflowing cell border.
	height: "auto",
	noEventsContent: "No announcement posts this week",
	dayMaxEvents: true,
	moreLinkContent: (arg: { num: number }) => `+${arg.num} more`,
	firstDay: 1 as const,
	highlightedDates: refused ? [] : highlightedDates,
	datesSet: (info: { start: Date; end: Date }) => {
		const next = datesSetWindow(info.start, info.end);
		if (range !== null && range.from === next.from && range.to === next.to)
			return;
		range = next;
	},
	eventClick: (info: { event: { id: string | number } }) => {
		const item = itemsById.get(String(info.event.id));
		if (item) onSelectItem?.(item);
	},
	eventContent: (info: { event: { id: string | number } }) => {
		const item = itemsById.get(String(info.event.id));
		if (!item) return { html: "" };
		const status = occurrenceStatus(item);
		const title = escapeHtml(occurrenceTitle(item));
		const label = escapeHtml(status.label);
		const time =
			item.postTime === null
				? ""
				: `<time>${escapeHtml(item.postTime.slice(0, 5))}</time>`;
		const readonlyMarker = item.readOnly
			? ` <span class="ta-event-holiday">read-only</span>`
			: "";
		return {
			html: `<div class="ta-event ta-tone--${status.tone}${item.readOnly ? " ta-event--readonly" : ""}" title="${title} — ${label}${item.readOnly ? " (read-only holiday notice)" : ""}"><div class="ta-event-meta"><span class="ta-event-status"><span class="ta-event-dot" aria-hidden="true"></span>${label}</span>${time}</div><div class="ta-event-title"><span class="ta-event-title-text">${title}</span>${readonlyMarker}</div>`,
		};
	},
	theme: (defaultTheme: Record<string, string | string[]>) => ({
		...defaultTheme,
		calendar: "ec dhc-calendar",
		view:
			view === "dayGridMonth"
				? "ec-day-grid ec-month-view"
				: "ec-list ec-week-view",
		header: "ec-header dhc-calendar-weekdays",
		toolbar: "ec-toolbar dhc-calendar-toolbar",
		button: "ec-button dhc-calendar-control",
		buttonGroup: "ec-button-group dhc-calendar-control-group",
		active: "ec-active",
		title: "ec-title dhc-calendar-title",
		body: "ec-body dhc-calendar-body",
		dayHead: "ec-day-head dhc-calendar-day-number",
		day: "ec-day dhc-calendar-day",
		today: "ec-today dhc-calendar-today",
		otherMonth: "ec-other-month dhc-calendar-other-month",
		event: "ec-event dhc-calendar-event",
		eventBody: "ec-event-body dhc-calendar-event-body",
		eventTitle: "ec-event-title",
		eventTime: "ec-event-time",
		popup: "ec-popup dhc-calendar-popup",
		highlight: "ec-highlight ta-holiday-day",
	}),
});

function backToToday() {
	anchor = today;
}
</script>

<section
	aria-label="Training announcement calendar"
	class="overflow-hidden rounded-2xl border border-border/80 bg-card shadow-sm"
	data-testid="training-calendar"
>
	<div
		class="flex flex-wrap items-center justify-between gap-3 px-4 pt-4 sm:px-5"
	>
		<ToggleGroup
			type="single"
			bind:value={view}
			variant="outline"
			size="sm"
			aria-label="Calendar view"
			data-testid="calendar-view"
		>
			<ToggleGroupItem
				value="dayGridMonth"
				aria-label="Month"
				class="px-3 font-semibold data-[state=on]:bg-primary data-[state=on]:text-primary-foreground"
				>Month</ToggleGroupItem
			>
			<ToggleGroupItem
				value="listWeek"
				aria-label="Week"
				class="px-3 font-semibold data-[state=on]:bg-primary data-[state=on]:text-primary-foreground"
				>Week</ToggleGroupItem
			>
		</ToggleGroup>
		<p class="text-xs text-muted-foreground" data-testid="calendar-count">
			{#if refused}
				History unavailable
			{:else if occurrences.data}
				{occurrences.data.length}
				{occurrences.data.length === 1 ? "post" : "posts"} in view
			{:else}
				Loading posts…
			{/if}
		</p>
	</div>

	{#if refused && range}
		<div class="px-4 pt-4 sm:px-5">
			<Alert data-testid="horizon-refusal">
				<TriangleAlert aria-hidden="true" />
				<AlertTitle
					>History is available from {announcementDateLabel(
						horizon,
					)}</AlertTitle
				>
				<AlertDescription>
					Posts older than 400 days are no longer available.
					<Button
						size="sm"
						variant="outline"
						class="mt-2"
						onclick={backToToday}
					>
						Back to today
					</Button>
				</AlertDescription>
			</Alert>
		</div>
	{/if}

	<div class="p-4 sm:p-5">
		{#if occurrences.isError && !refused}
			<Alert variant="destructive" class="mb-4">
				<AlertDescription class="flex items-center justify-between gap-4">
					<span
						>{apiErrorMessage(
							occurrences.error,
							"Could not load the announcement posts",
						)}</span
					>
					<Button variant="outline" onclick={() => occurrences.refetch()}
						>Try again</Button
					>
				</AlertDescription>
			</Alert>
		{/if}
		<!-- Always mounted: the calendar's `datesSet` callback is what reports
		     the visible range, so hiding it behind a loader would deadlock the
		     very read the loader waits for. -->
		<!-- Remount on view or anchor change: switching `view` through the
		     reactive options prop leaves event-calendar's root view classes
		     stale, so the next plugin renders without its CSS. -->
		{#key `${view}:${anchor}`}
			<Calendar plugins={[DayGrid, List, Interaction]} {options} />
		{/key}
	</div>
</section>

<style>
/* Event chips only. Chrome (toolbar, weekday header, day cells, today ring,
 * event wrapper reset, more-link, popup) lives in the shared
 * $lib/components/calendar/dhc-calendar.css imported above. */
:global(.ta-holiday-day) {
	background: repeating-linear-gradient(
		-45deg,
		hsl(var(--destructive) / 0.06) 0 6px,
		transparent 6px 12px
	);
}

:global(.ta-event) {
	width: 100%;
	min-width: 0;
	border: 1px solid hsl(var(--border) / 0.78);
	border-left-width: 3px;
	border-left-color: var(--ta-tone, hsl(var(--muted-foreground)));
	border-radius: 0.625rem;
	background: hsl(var(--card));
	padding: 0.3rem 0.45rem;
	color: hsl(var(--foreground));
	box-shadow: 0 1px 2px rgb(0 0 0 / 5%);
}

:global(.ta-event--readonly) {
	border-style: dashed;
}

:global(.ta-event-meta) {
	display: flex;
	min-width: 0;
	align-items: center;
	justify-content: space-between;
	gap: 0.375rem;
	color: hsl(var(--muted-foreground));
	font-size: 0.6rem;
	font-weight: 800;
	letter-spacing: 0.06em;
	line-height: 1.2;
	text-transform: uppercase;
}

:global(.ta-event-meta time) {
	font-variant-numeric: tabular-nums;
	letter-spacing: 0;
}

:global(.ta-event-status) {
	display: inline-flex;
	min-width: 0;
	align-items: center;
	gap: 0.3rem;
	overflow: hidden;
	white-space: nowrap;
}

:global(.ta-event-dot) {
	width: 0.45rem;
	height: 0.45rem;
	flex: none;
	border-radius: 9999px;
	background: var(--ta-tone, hsl(var(--muted-foreground)));
}

/* Single line with ellipsis: at pinned height a wrapping title would push
 * lone chips behind the "+N more" link, on phones first. The full title and
 * status stay one hover away in the chip's `title` attribute. */
:global(.ta-event-title) {
	display: flex;
	align-items: baseline;
	gap: 0.3rem;
	margin-top: 0.15rem;
	overflow: hidden;
	font-size: 0.72rem;
	font-weight: 800;
	line-height: 1.25;
}

:global(.ta-event-title-text) {
	flex: 1 1 auto;
	overflow: hidden;
	/* Never collapse to zero under the read-only tag: on phone widths the
	 * row clips instead, so a lone chip stays visible with its title start. */
	min-width: 2ch;
	white-space: nowrap;
	text-overflow: ellipsis;
}

:global(.ta-event-holiday) {
	flex: none;
	border: 1px solid currentColor;
	border-radius: 9999px;
	padding: 0.08rem 0.3rem;
	font-size: 0.55rem;
	font-weight: 800;
	line-height: 1;
	letter-spacing: 0.04em;
	text-transform: uppercase;
}

/* Week-list rows have room for readable copy; do not reuse month-chip sizing. */
:global(.ec-list .ta-event) {
	display: grid;
	grid-template-columns: minmax(0, 1fr) auto;
	gap: 0.375rem 1rem;
	border: 0;
	border-radius: 0;
	background: transparent;
	padding: 1rem;
	box-shadow: none;
}

:global(.ec-list .ta-event-meta) {
	display: contents;
	font-size: 0.75rem;
	font-weight: 600;
	letter-spacing: 0;
	text-transform: none;
}

:global(.ec-list .ta-event-status) {
	grid-column: 1;
	grid-row: 2;
}

:global(.ec-list .ta-event-meta time) {
	grid-column: 2;
	grid-row: 1 / 3;
	align-self: center;
	font-size: 0.875rem;
}

:global(.ec-list .ta-event-title) {
	grid-column: 1;
	grid-row: 1;
	margin-top: 0;
	font-size: 0.9375rem;
	font-weight: 600;
	line-height: 1.4;
}

:global(.ec-list .ta-event-title-text) {
	white-space: normal;
	overflow-wrap: anywhere;
}

/* Phone widths: a chip in a ~44px column cannot hold a status word and a title.
 * The word goes and the tone stays — the dot keeps the status colour and the
 * chip's `title` attribute keeps the full "title — status" pair for a hover or
 * a screen reader. The title keeps the desktop single-line ellipsis: letting it
 * wrap makes the chip tall enough that event-calendar hides it behind "+N more",
 * which loses the post entirely rather than shortening it. */
@media (max-width: 640px) {
	:global(.ec-day-grid .ta-event) {
		padding: 0.2rem 0.3rem;
	}

	:global(.ec-day-grid .ta-event-meta) {
		font-size: 0.5rem;
		letter-spacing: 0.02em;
	}

	:global(.ec-day-grid .ta-event-dot) {
		width: 0.35rem;
		height: 0.35rem;
	}

	/* The status label is the first child of `.ta-event-status`, the dot the
	 * second; hiding only the word leaves the tone marker in place. */
	:global(.ec-day-grid .ta-event-status) {
		font-size: 0;
	}

	:global(.ec-day-grid .ta-event-status .ta-event-dot) {
		font-size: 0.5rem;
	}

	:global(.ec-day-grid .ta-event-title) {
		margin-top: 0.1rem;
		font-size: 0.65rem;
		line-height: 1.2;
	}

	/* Same for the read-only pill: the dashed border and the `title` still say
	 * read-only, and the width goes to the title instead. */
	:global(.ec-day-grid .ta-event-holiday) {
		display: none;
	}
}
</style>
