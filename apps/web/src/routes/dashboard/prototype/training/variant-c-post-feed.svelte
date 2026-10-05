<!--
	PROTOTYPE — throwaway. Variant C — "Post feed".
	The calendar is a schedule of Discord posts, so show the posts: the List view
	renders every upcoming occurrence as the message it will become, in order, with
	bank-holiday announcements in the same stream and delivery evidence on past rows.
	Actions are inline on the row; creating a Training is a composer card at the top,
	and Trainings are chips that filter the feed and toggle enablement.
-->
<script lang="ts">
import { Calendar, List } from "@event-calendar/core";
import "@event-calendar/core/index.css";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import { Switch } from "$lib/components/ui/switch";
import { Textarea } from "$lib/components/ui/textarea";
import dayjs from "dayjs";
import { ChevronDown, Plus, X } from "@lucide/svelte";
import DiscordPreview from "./discord-preview.svelte";
import TrainingFormFields from "./training-form-fields.svelte";
import {
	ANNOUNCEMENT_CHANNEL,
	CHANNEL,
	DELIVERY_LABEL,
	KIND_LABEL,
	STATUS_LABEL,
	TODAY,
	announcementsBetween,
	decisionLabel,
	formatLongDate,
	formatRange,
	occurrencesBetween,
	resolveOccurrence,
	scheduleLabel,
	statusOf,
	store,
	emptyDraft,
	type TrainingDraft,
	type NotificationKind,
} from "./training-prototype-store.svelte";

function escapeHtml(value: string) {
	return value.replace(
		/[&<>"']/g,
		(c) =>
			({
				"&": "&amp;",
				"<": "&lt;",
				">": "&gt;",
				'"': "&quot;",
				"'": "&#039;",
			})[c]!,
	);
}

function renderBody(rendered: string) {
	return rendered
		.split("\n")
		.map((line) =>
			line === "@everyone"
				? '<span class="tr-feed-mention">@everyone</span>'
				: escapeHtml(line),
		)
		.join("<br>");
}

let kindFilter = $state<NotificationKind | "all">("all");
let hiddenTrainings = $state<Set<string>>(new Set());
// Fixed wide window: the list only shows what falls inside its own view range.
const range = {
	start: dayjs(TODAY).subtract(8, "week").toDate(),
	end: dayjs(TODAY).add(26, "week").toDate(),
};

const occurrences = $derived(
	occurrencesBetween(range.start, range.end).filter(
		(o) =>
			(kindFilter === "all" || o.training.kind === kindFilter) &&
			!hiddenTrainings.has(o.training.id),
	),
);
const announcements = $derived(announcementsBetween(range.start, range.end));
const byKey = $derived(new Map(occurrences.map((o) => [o.key, o])));
const announcementByKey = $derived(
	new Map(announcements.map((a) => [a.key, a])),
);

const events = $derived([
	...occurrences.map((o) => ({
		id: o.key,
		title: o.title,
		start: `${o.date} ${o.startTime}`,
		end: `${o.date} ${o.endTime}`,
		extendedProps: { type: "occurrence" },
	})),
	...announcements.map((a) => ({
		id: a.key,
		title: a.holiday.name,
		start: `${a.date} 09:00`,
		end: `${a.date} 09:05`,
		extendedProps: { type: "announcement" },
	})),
]);

// --- inline editors --------------------------------------------------------------
let composerOpen = $state(false);
let draft = $state<TrainingDraft>(emptyDraft());
let copyEdit = $state<{
	trainingId: string;
	date: string;
	to: string;
	title: string;
	message: string;
	error: string;
} | null>(null);

function createTraining() {
	const schedule =
		draft.scheduleType === "weekly"
			? {
					type: "weekly" as const,
					weekday: draft.weekday,
					startTime: draft.startTime,
					endTime: draft.endTime,
				}
			: {
					type: "one_off" as const,
					date: draft.date,
					startTime: draft.startTime,
					endTime: draft.endTime,
				};
	store.add({
		kind: draft.kind,
		title: draft.title,
		message: draft.message,
		everyone: draft.everyone,
		enabled: true,
		schedule,
	});
	composerOpen = false;
	draft = emptyDraft();
}

function handleFeedClick(event: MouseEvent) {
	if (!(event.target instanceof HTMLElement)) return;
	const target = event.target.closest<HTMLElement>("[data-action]");
	if (!target) return;
	event.preventDefault();
	event.stopPropagation();
	const key = target.dataset.key!;
	const o = byKey.get(key);
	if (!o) return;
	switch (target.dataset.action) {
		case "skip":
			store.suppress({ trainingId: o.training.id, from: o.date, to: o.date });
			break;
		case "unskip":
			if (o.suppression) store.unsuppress(o.suppression.id);
			break;
		case "edit-copy":
			copyEdit = {
				trainingId: o.training.id,
				date: o.date,
				to: o.date,
				title: o.override?.title ?? o.training.title,
				message: o.override?.message ?? o.training.message,
				error: "",
			};
			if (o.override) store.removeOverride(o.override.id);
			break;
		case "remove-copy":
			if (o.override) store.removeOverride(o.override.id);
			break;
	}
}

function saveCopy() {
	if (!copyEdit) return;
	const result = store.override({
		trainingId: copyEdit.trainingId,
		from: copyEdit.date,
		to: copyEdit.to,
		title: copyEdit.title,
		message: copyEdit.message,
	});
	if (!result.ok) {
		copyEdit.error = result.error;
		return;
	}
	copyEdit = null;
}

const copyPreview = $derived.by(() => {
	if (!copyEdit) return null;
	const training = store.get(copyEdit.trainingId);
	return training
		? resolveOccurrence(
				{ ...training, title: copyEdit.title, message: copyEdit.message },
				copyEdit.date,
			)
		: null;
});

const counts = $derived({
	posts: occurrences.filter((o) => !o.past && o.willPost).length,
	skipped: occurrences.filter((o) => !o.past && !o.willPost).length,
	announcements: announcements.filter((a) => !a.past).length,
});

// --- list options -------------------------------------------------------------------
const options = $derived({
	view: "listWeek",
	duration: { days: 28 },
	date: TODAY,
	events,
	headerToolbar: { start: "title", center: "", end: "today prev,next" },
	buttonText: { today: "From today" },
	height: "auto",
	firstDay: 1 as const,
	listDayFormat: {
		weekday: "long",
		day: "numeric",
		month: "long",
	} satisfies Intl.DateTimeFormatOptions,
	listDaySideFormat: () => "",
	noEventsContent: "No posts in this period.",
	eventContent: (info: Calendar.EventContentInfo) => {
		if (info.event.extendedProps.type === "announcement") {
			const a = announcementByKey.get(String(info.event.id));
			if (!a) return { html: "" };
			return {
				html: `<article class="tr-feed tr-feed--announcement${a.past ? " tr-feed--past" : ""}">
					<div class="tr-feed-head">
						<span class="tr-feed-kind">Bank holiday · ${a.phase === "day_before" ? "day before" : "same day"} · ${ANNOUNCEMENT_CHANNEL} · 09:00</span>
						<span class="tr-pill tr-pill--${a.past ? "delivered" : "bank_holiday"}">${a.past ? "Delivered" : "Automatic"}</span>
					</div>
					<div class="tr-feed-body">${renderBody(a.rendered)}</div>
					<div class="tr-feed-foot"><span>Fixed copy from the club bot; suppresses every Training on ${escapeHtml(formatLongDate(a.holiday.date))}.</span></div>
				</article>`,
			};
		}
		const o = byKey.get(String(info.event.id));
		if (!o) return { html: "" };
		const status = statusOf(o);
		const actions: string[] = [];
		if (!o.past && o.decision !== "bank_holiday" && o.decision !== "disabled") {
			actions.push(
				o.suppression
					? `<button type="button" data-action="unskip" data-key="${o.key}">Post after all</button>`
					: `<button type="button" data-action="skip" data-key="${o.key}">Skip</button>`,
			);
			if (!o.suppression) {
				actions.push(
					`<button type="button" data-action="edit-copy" data-key="${o.key}">${o.override ? "Edit copy" : "Change copy"}</button>`,
				);
				if (o.override)
					actions.push(
						`<button type="button" data-action="remove-copy" data-key="${o.key}">Back to default</button>`,
					);
			}
		}
		const evidence =
			o.past && o.delivery
				? `<span>${escapeHtml(DELIVERY_LABEL[o.delivery.state])}${o.delivery.messageId ? ` · message ${o.delivery.messageId}` : ""}${o.delivery.threadId ? ` · thread ${o.delivery.threadId}` : ""}${o.delivery.reason ? ` · ${escapeHtml(o.delivery.reason)}` : ""}</span>`
				: o.willPost
					? `<span>${escapeHtml(decisionLabel(o.decision))}${o.override ? ` · ${escapeHtml(formatRange(o.override.from, o.override.to))}` : ""} · freezes at ${o.startTime}</span>`
					: `<span>Nothing posts — ${escapeHtml(decisionLabel(o.decision, o.holiday).toLowerCase())}${o.suppression?.note ? ` · ${escapeHtml(o.suppression.note)}` : ""}</span>`;
		return {
			html: `<article class="tr-feed tr-feed--${status}${o.past ? " tr-feed--past" : ""}${!o.willPost && !o.past ? " tr-feed--struck" : ""}">
				<div class="tr-feed-head">
					<span class="tr-feed-kind">${KIND_LABEL[o.training.kind]} · ${CHANNEL[o.training.kind]} · ${o.startTime}${o.training.schedule.type === "one_off" ? " · one-off" : ""}</span>
					<span class="tr-pill tr-pill--${status}">${escapeHtml(STATUS_LABEL[status] ?? status)}</span>
				</div>
				<div class="tr-feed-body">${renderBody(o.rendered)}</div>
				<div class="tr-feed-thread">${escapeHtml(o.threadName)}<span> · thread</span></div>
				<div class="tr-feed-foot">${evidence}<span class="tr-feed-actions">${actions.join("")}</span></div>
			</article>`,
		};
	},
	theme: (t: Record<string, string | string[]>) => ({
		...t,
		calendar: "ec workshop-calendar tr-calendar tr-list",
		toolbar: "ec-toolbar workshop-calendar-toolbar",
		button: "ec-button workshop-calendar-control",
		buttonGroup: "ec-button-group workshop-calendar-control-group",
		title: "ec-title workshop-calendar-title",
		event: "ec-event tr-list-event",
	}),
});
</script>

<div class="space-y-6">
	<header
		class="flex flex-col gap-4 border-b border-border/80 pb-6 sm:flex-row sm:items-end sm:justify-between"
	>
		<div class="max-w-2xl space-y-2">
			<p class="text-xs font-bold tracking-[0.18em] text-primary uppercase">
				Training
			</p>
			<h1 class="text-3xl font-bold tracking-tight sm:text-4xl">
				Upcoming Discord posts
			</h1>
			<p class="text-base leading-7 text-muted-foreground">
				Read the month as the bot will post it. Skip a post or change its copy
				from the row; bank-holiday announcements sit in the same stream.
			</p>
		</div>
		<div class="flex gap-6 text-sm">
			<div>
				<p class="text-2xl font-bold tabular-nums">{counts.posts}</p>
				<p class="text-muted-foreground">posts</p>
			</div>
			<div>
				<p class="text-2xl font-bold tabular-nums">{counts.skipped}</p>
				<p class="text-muted-foreground">skipped</p>
			</div>
			<div>
				<p class="text-2xl font-bold tabular-nums">{counts.announcements}</p>
				<p class="text-muted-foreground">holiday notices</p>
			</div>
		</div>
	</header>

	<!-- Trainings as chips -->
	<div class="flex flex-wrap items-center gap-2">
		<div class="mr-2 inline-flex rounded-xl border p-1 text-xs font-semibold">
			{#each [["all", "All"], ["roll_call", "Roll call"], ["sparring", "Sparring"]] as const as [value, label] (value)}
				<button
					type="button"
					class="cursor-pointer rounded-lg px-3 py-1.5 transition-colors"
					class:bg-primary={kindFilter === value}
					class:text-primary-foreground={kindFilter === value}
					onclick={() => (kindFilter = value)}>{label}</button
				>
			{/each}
		</div>
		{#each store.trainings as training (training.id)}
			<div
				class="inline-flex items-center gap-2 rounded-xl border bg-card px-3 py-1.5 text-sm"
				class:opacity-60={!training.enabled}
			>
				<button
					type="button"
					class="cursor-pointer text-left hover:text-primary"
					class:line-through={hiddenTrainings.has(training.id)}
					onclick={() => {
						const next = new Set(hiddenTrainings);
						next.has(training.id)
							? next.delete(training.id)
							: next.add(training.id);
						hiddenTrainings = next;
					}}
					title="Show/hide in feed"
				>
					<span
						class="block text-[0.625rem] font-bold tracking-[0.12em] text-muted-foreground uppercase"
						>{KIND_LABEL[training.kind]}</span
					>
					<span class="block font-semibold">{training.title}</span>
					<span class="block text-xs text-muted-foreground"
						>{scheduleLabel(training)}</span
					>
				</button>
				<Switch
					checked={training.enabled}
					onCheckedChange={(v) => store.setEnabled(training.id, v)}
					aria-label="Enabled"
				/>
			</div>
		{/each}
		<Button
			variant={composerOpen ? "secondary" : "outline"}
			onclick={() => (composerOpen = !composerOpen)}
		>
			<Plus aria-hidden="true" /> Add Training
			<ChevronDown
				aria-hidden="true"
				class="transition-transform {composerOpen ? 'rotate-180' : ''}"
			/>
		</Button>
	</div>

	{#if composerOpen}
		<section class="rounded-2xl border-2 border-primary/40 bg-card p-5">
			<div class="mb-4 flex items-center justify-between">
				<h2 class="font-bold">New Training</h2>
				<Button
					variant="ghost"
					size="icon"
					aria-label="Close"
					onclick={() => (composerOpen = false)}
					><X aria-hidden="true" /></Button
				>
			</div>
			<TrainingFormFields bind:draft idPrefix="c" />
			<div class="mt-4 flex justify-end gap-2">
				<Button variant="ghost" onclick={() => (composerOpen = false)}
					>Cancel</Button
				>
				<Button onclick={createTraining}>Create Training</Button>
			</div>
		</section>
	{/if}

	{#if copyEdit}
		<section
			class="grid gap-4 rounded-2xl border-2 border-secondary/60 bg-card p-5 md:grid-cols-[minmax(0,1fr)_minmax(0,22rem)]"
		>
			<div class="space-y-3">
				<div class="flex items-center justify-between">
					<h2 class="font-bold">
						Change copy · {formatLongDate(copyEdit.date)}{copyEdit.to !==
						copyEdit.date
							? ` → ${formatLongDate(copyEdit.to)}`
							: ""}
					</h2>
					<Button
						variant="ghost"
						size="icon"
						aria-label="Close"
						onclick={() => (copyEdit = null)}><X aria-hidden="true" /></Button
					>
				</div>
				<div class="grid gap-3 sm:grid-cols-[1fr_1fr]">
					<div class="space-y-1.5">
						<Label for="c-ov-to">Until (optional range)</Label><Input
							id="c-ov-to"
							type="date"
							min={copyEdit.date}
							bind:value={copyEdit.to}
						/>
					</div>
					<div class="space-y-1.5">
						<Label for="c-ov-title">Title</Label><Input
							id="c-ov-title"
							bind:value={copyEdit.title}
							maxlength={100}
						/>
					</div>
				</div>
				<div class="space-y-1.5">
					<Label for="c-ov-message">Message</Label><Textarea
						id="c-ov-message"
						rows={3}
						bind:value={copyEdit.message}
					/>
				</div>
				{#if copyEdit.error}<p class="text-sm font-semibold text-destructive">
						{copyEdit.error}
					</p>{/if}
				<div class="flex justify-end gap-2">
					<Button variant="ghost" onclick={() => (copyEdit = null)}
						>Cancel</Button
					>
					<Button onclick={saveCopy}>Save copy</Button>
				</div>
			</div>
			{#if copyPreview}
				<DiscordPreview
					channel={CHANNEL[copyPreview.training.kind]}
					rendered={copyPreview.rendered}
					threadName={copyPreview.threadName}
					compact
				/>
			{/if}
		</section>
	{/if}

	<!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
	<!-- Delegated click: the real controls are <button>s rendered inside the List view, so keyboard works natively. -->
	<div
		class="workshop-calendar-container overflow-hidden rounded-2xl border border-border/80 bg-card shadow-sm"
		onclick={handleFeedClick}
	>
		<Calendar plugins={[List]} {options} />
	</div>
</div>

<style>
:global(.tr-list .ec-body) {
	padding: 0.5rem 1rem 1rem;
}

:global(.tr-list .ec-day-head) {
	margin: 1rem 0 0.5rem;
	border: 0;
	background: transparent;
	font-family: var(--font-heading), serif;
	font-size: 1rem;
	font-weight: 700;
	color: hsl(var(--foreground));
}

:global(.tr-list .ec-day-head time) {
	color: hsl(var(--foreground));
}

:global(.tr-list .ec-day.ec-today .ec-day-head::after) {
	content: "Today";
	margin-left: 0.6rem;
	border-radius: 9999px;
	background: hsl(var(--primary));
	padding: 0.1rem 0.5rem;
	color: hsl(var(--primary-foreground));
	font-size: 0.625rem;
	font-weight: 800;
	letter-spacing: 0.08em;
	text-transform: uppercase;
	vertical-align: middle;
}

:global(.tr-list .tr-list-event) {
	display: block;
	border: 0;
	background: transparent;
	padding: 0 0 0.5rem;
	cursor: default;
}

:global(.tr-list .tr-list-event .ec-event-time) {
	display: none;
}

:global(.tr-list .tr-list-event .ec-event-title) {
	display: block;
}

:global(.tr-feed) {
	display: grid;
	gap: 0.4rem;
	border: 1px solid hsl(var(--border) / 0.8);
	border-left: 4px solid var(--tr-status, hsl(var(--primary)));
	border-radius: 0.9rem;
	background: color-mix(
		in oklab,
		var(--tr-status, hsl(var(--primary))) 4%,
		hsl(var(--card))
	);
	padding: 0.75rem 1rem;
	font-size: 0.875rem;
}

:global(.tr-feed--past) {
	opacity: 0.7;
}

:global(.tr-feed--struck .tr-feed-body) {
	text-decoration: line-through;
	color: hsl(var(--muted-foreground));
}

:global(.tr-feed--announcement) {
	border-style: dashed;
}

:global(.tr-feed--default) {
	--tr-status: hsl(var(--primary));
}
:global(.tr-feed--overridden) {
	--tr-status: hsl(var(--secondary));
}
:global(.tr-feed--suppressed),
:global(.tr-feed--skipped) {
	--tr-status: hsl(var(--muted-foreground));
}
:global(.tr-feed--disabled) {
	--tr-status: hsl(var(--muted-foreground) / 0.6);
}
:global(.tr-feed--bank_holiday),
:global(.tr-feed--announcement),
:global(.tr-feed--blocked),
:global(.tr-feed--missed) {
	--tr-status: hsl(var(--destructive));
}
:global(.tr-feed--delivered) {
	--tr-status: hsl(142 60% 40%);
}
:global(.tr-feed--thread_failed) {
	--tr-status: hsl(38 92% 45%);
}
:global(.tr-feed--message_uncertain) {
	--tr-status: hsl(280 60% 50%);
}

:global(.tr-feed-head) {
	display: flex;
	align-items: center;
	justify-content: space-between;
	gap: 0.5rem;
}

:global(.tr-feed-kind) {
	color: hsl(var(--muted-foreground));
	font-size: 0.6875rem;
	font-weight: 800;
	letter-spacing: 0.1em;
	text-transform: uppercase;
}

:global(.tr-feed-body) {
	line-height: 1.5;
	white-space: normal;
}

:global(.tr-feed-mention) {
	border-radius: 0.25rem;
	background: hsl(var(--primary) / 0.18);
	padding: 0 0.25rem;
	color: hsl(var(--primary));
	font-weight: 600;
}

:global(.tr-feed-thread) {
	display: inline-flex;
	width: fit-content;
	gap: 0.25rem;
	border: 1px solid hsl(var(--border) / 0.7);
	border-radius: 0.5rem;
	background: hsl(var(--muted) / 0.4);
	padding: 0.15rem 0.5rem;
	font-size: 0.75rem;
	font-weight: 600;
}

:global(.tr-feed-thread span) {
	color: hsl(var(--muted-foreground));
	font-weight: 500;
}

:global(.tr-feed-foot) {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	justify-content: space-between;
	gap: 0.5rem;
	color: hsl(var(--muted-foreground));
	font-size: 0.75rem;
}

:global(.tr-feed-actions) {
	display: inline-flex;
	gap: 0.25rem;
}

:global(.tr-feed-actions button) {
	border: 1px solid hsl(var(--border));
	border-radius: 0.5rem;
	background: hsl(var(--background));
	padding: 0.25rem 0.6rem;
	color: hsl(var(--foreground));
	font-size: 0.75rem;
	font-weight: 700;
	cursor: pointer;
	transition:
		border-color 180ms ease,
		background-color 180ms ease,
		color 180ms ease;
}

:global(.tr-feed-actions button:hover) {
	border-color: hsl(var(--primary) / 0.5);
	background: hsl(var(--primary) / 0.08);
	color: hsl(var(--primary));
}
</style>
