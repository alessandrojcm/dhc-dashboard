<!--
	The Training Announcements calendar (ALE-332): every Announcement
	Occurrence and Holiday Announcement in the visible range, read from the
	`window` read model across all announcements.

	- Month/Week views over `@event-calendar/core`, chrome from the shared
	  `$lib/components/calendar/dhc-calendar.css`, chips styled here. The view
	  switch is owned by Svelte state and remounts the calendar (`{#key}`):
	  pushing `view` through the reactive options leaves event-calendar's root
	  view classes stale, so TimeGrid renders without its CSS.
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
import { Calendar, DayGrid, Interaction, TimeGrid } from "@event-calendar/core";
import "@event-calendar/core/index.css";
import "$lib/components/calendar/dhc-calendar.css";
import "./occurrence-tone.css";
import { Alert, AlertDescription, AlertTitle } from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";
import { TriangleAlert } from "@lucide/svelte";
import { apiErrorMessage } from "$lib/api-error";
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

/** Pinned height: switching Month/Week never moves the content below. */
const CALENDAR_HEIGHT = "40rem";

let view = $state<"dayGridMonth" | "timeGridWeek">("dayGridMonth");
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
	buttonText: { today: "Today" },
	height: CALENDAR_HEIGHT,
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
	<div class="flex flex-wrap items-center justify-between gap-3 px-5 pt-4">
		<div
			class="inline-flex rounded-xl border p-1 text-xs font-semibold"
			role="group"
			aria-label="Calendar view"
		>
			<button
				type="button"
				class="cursor-pointer rounded-lg px-3 py-1.5 transition-colors {view ===
				'dayGridMonth'
					? 'bg-primary text-primary-foreground'
					: ''}"
				aria-pressed={view === "dayGridMonth"}
				onclick={() => (view = "dayGridMonth")}>Month</button
			>
			<button
				type="button"
				class="cursor-pointer rounded-lg px-3 py-1.5 transition-colors {view ===
				'timeGridWeek'
					? 'bg-primary text-primary-foreground'
					: ''}"
				aria-pressed={view === "timeGridWeek"}
				onclick={() => (view = "timeGridWeek")}>Week</button
			>
		</div>
		<p class="text-xs text-muted-foreground" data-testid="calendar-count">
			{#if refused}
				Showing no history before the retention horizon
			{:else if occurrences.data}
				{occurrences.data.length}
				{occurrences.data.length === 1 ? "post" : "posts"} in view
			{:else}
				Loading posts…
			{/if}
		</p>
	</div>

	{#if refused && range}
		<div class="px-5 pt-4">
			<Alert data-testid="horizon-refusal">
				<TriangleAlert aria-hidden="true" />
				<AlertTitle>History before {range.from} is not kept</AlertTitle>
				<AlertDescription>
					The club keeps {horizon} onwards — 400 days of announcement history. Anything
					earlier expired and is gone, so the calendar refuses to show recomputed
					or empty history instead of misleading you.
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

	<div class="p-5">
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
		     stale, so TimeGrid renders without its CSS. -->
		{#key `${view}:${anchor}`}
			<Calendar plugins={[DayGrid, TimeGrid, Interaction]} {options} />
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
</style>
