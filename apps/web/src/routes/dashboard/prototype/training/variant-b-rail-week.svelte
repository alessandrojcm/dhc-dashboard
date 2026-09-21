<!--
	PROTOTYPE — throwaway. Variant B — "Trainings rail + week timeline".
	The Training is the primary object: pick one in the left rail, and the right
	side shows its week timeline (TimeGrid — posts have times), its exceptions as
	lists, and its recent deliveries. Every edit happens in a side Sheet so the
	calendar never leaves view. Other Trainings stay visible but dimmed on the
	timeline so collisions are obvious.
-->
<script lang="ts">
import { Calendar, TimeGrid, Interaction } from "@event-calendar/core";
import "@event-calendar/core/index.css";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import * as Sheet from "$lib/components/ui/sheet";
import { Switch } from "$lib/components/ui/switch";
import { Textarea } from "$lib/components/ui/textarea";
import dayjs from "dayjs";
import {
	AlertTriangle,
	CalendarOff,
	Pencil,
	Plus,
	Trash2,
	X,
} from "@lucide/svelte";
import DiscordPreview from "./discord-preview.svelte";
import TrainingFormFields from "./training-form-fields.svelte";
import {
	CHANNEL,
	DELIVERY_LABEL,
	HOLIDAYS,
	KIND_LABEL,
	STATUS_LABEL,
	TODAY,
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
	upcomingOccurrences,
	type Occurrence,
	type Training,
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

let selectedId = $state<string>(store.trainings[0]?.id ?? "");
const selected = $derived(store.get(selectedId) ?? store.trainings[0]);

let range = $state({
	start: dayjs(TODAY).startOf("week").toDate(),
	end: dayjs(TODAY).endOf("week").add(1, "day").toDate(),
});
const occurrences = $derived(occurrencesBetween(range.start, range.end));
const byKey = $derived(new Map(occurrences.map((o) => [o.key, o])));

const events = $derived(
	occurrences.map((o) => ({
		id: o.key,
		title: o.title,
		start: `${o.date} ${o.startTime}`,
		end: `${o.date} ${o.endTime}`,
	})),
);

let focusKey = $state<string | null>(null);
const focused = $derived(focusKey ? (byKey.get(focusKey) ?? null) : null);

const upcoming = $derived(selected ? upcomingOccurrences(selected, 8) : []);
const recent = $derived(
	selected
		? occurrencesBetween(dayjs(TODAY).subtract(5, "week").toDate(), TODAY)
				.filter((o) => o.training.id === selected.id)
				.reverse()
		: [],
);
const collisions = $derived.by(() => {
	const seen = new Map<string, Occurrence[]>();
	for (const o of occurrences) {
		const slot = `${o.date} ${o.startTime}`;
		seen.set(slot, [...(seen.get(slot) ?? []), o]);
	}
	return [...seen.values()].filter((group) => group.length > 1);
});

// --- sheet ----------------------------------------------------------------------
type SheetMode =
	| { kind: "training"; editingId: string | null }
	| { kind: "suppress"; from: string; to: string; note: string }
	| {
			kind: "override";
			from: string;
			to: string;
			title: string;
			message: string;
			error: string;
	  };
let sheet = $state<SheetMode | null>(null);
let draft = $state<TrainingDraft>(emptyDraft());

function openCreate() {
	draft = emptyDraft();
	sheet = { kind: "training", editingId: null };
}
function openEdit(training: Training) {
	draft = {
		kind: training.kind,
		scheduleType: training.schedule.type,
		weekday:
			training.schedule.type === "weekly" ? training.schedule.weekday : 1,
		date: training.schedule.type === "one_off" ? training.schedule.date : TODAY,
		startTime: training.schedule.startTime,
		endTime: training.schedule.endTime,
		title: training.title,
		message: training.message,
		everyone: training.everyone,
	};
	sheet = { kind: "training", editingId: training.id };
}
function saveTraining() {
	if (!sheet || sheet.kind !== "training") return;
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
	if (sheet.editingId) {
		store.update(sheet.editingId, {
			title: draft.title,
			message: draft.message,
			everyone: draft.everyone,
			schedule,
		});
	} else {
		const created = store.add({
			kind: draft.kind,
			title: draft.title,
			message: draft.message,
			everyone: draft.everyone,
			enabled: true,
			schedule,
		});
		selectedId = created.id;
	}
	sheet = null;
}
function openSuppress(from = TODAY, to = from) {
	sheet = { kind: "suppress", from, to, note: "" };
}
function openOverride(from = TODAY, to = from) {
	if (!selected) return;
	sheet = {
		kind: "override",
		from,
		to,
		title: selected.title,
		message: selected.message,
		error: "",
	};
}
function saveException() {
	if (!sheet || !selected) return;
	if (sheet.kind === "suppress") {
		store.suppress({
			trainingId: selected.id,
			from: sheet.from,
			to: sheet.to,
			note: sheet.note || undefined,
		});
		sheet = null;
	} else if (sheet.kind === "override") {
		const result = store.override({
			trainingId: selected.id,
			from: sheet.from,
			to: sheet.to,
			title: sheet.title,
			message: sheet.message,
		});
		if (!result.ok) {
			sheet.error = result.error;
			return;
		}
		sheet = null;
	}
}
const overridePreview = $derived.by(() => {
	if (!sheet || sheet.kind !== "override" || !selected) return null;
	return resolveOccurrence(
		{ ...selected, title: sheet.title, message: sheet.message },
		sheet.from,
	);
});
const suppressAffected = $derived.by(() => {
	if (!sheet || sheet.kind !== "suppress" || !selected) return 0;
	const { from, to } = sheet;
	return upcomingOccurrences(selected, 60).filter(
		(o) => o.date >= from && o.date <= to,
	).length;
});

// --- calendar ---------------------------------------------------------------------
const options = $derived({
	view: "timeGridWeek",
	date: TODAY,
	events,
	headerToolbar: { start: "title", center: "", end: "today prev,next" },
	buttonText: { today: "This week" },
	height: "auto",
	firstDay: 1 as const,
	allDaySlot: false,
	nowIndicator: false,
	slotDuration: "00:15",
	slotLabelInterval: "01:00",
	slotMinTime: "08:00",
	slotMaxTime: "13:00",
	flexibleSlotTimeLimits: true,
	highlightedDates: HOLIDAYS.map((h) => h.date),
	datesSet: (info: { start: Date; end: Date }) => {
		// Only write when the window moved; a fresh object every call re-renders the calendar forever.
		if (
			range.start.getTime() === info.start.getTime() &&
			range.end.getTime() === info.end.getTime()
		)
			return;
		range = { start: info.start, end: info.end };
	},
	eventClick: (info: { event: { id: string | number } }) => {
		const o = byKey.get(String(info.event.id));
		if (!o) return;
		selectedId = o.training.id;
		focusKey = o.key;
	},
	eventClassNames: (info: { event: { id: string | number } }) => {
		const o = byKey.get(String(info.event.id));
		return o && selected && o.training.id !== selected.id ? "tr-week-dim" : "";
	},
	eventContent: (info: Calendar.EventContentInfo) => {
		const o = byKey.get(String(info.event.id));
		if (!o) return { html: "" };
		const status = statusOf(o);
		return {
			html: `<div class="tr-event tr-event--${status} tr-event--compact${!o.willPost && !o.past ? " tr-event--struck" : ""}" title="${escapeHtml(o.title)}"><span class="tr-event-dot"></span><span class="tr-event-title">${escapeHtml(o.title)}</span></div>`,
		};
	},
	theme: (t: Record<string, string | string[]>) => ({
		...t,
		calendar: "ec workshop-calendar tr-calendar tr-week",
		header: "ec-header workshop-calendar-weekdays",
		toolbar: "ec-toolbar workshop-calendar-toolbar",
		button: "ec-button workshop-calendar-control",
		buttonGroup: "ec-button-group workshop-calendar-control-group",
		title: "ec-title workshop-calendar-title",
		body: "ec-body workshop-calendar-body",
		dayHead: "ec-day-head workshop-calendar-day-number",
		day: "ec-day workshop-calendar-day",
		today: "ec-today workshop-calendar-today",
		event: "ec-event workshop-calendar-event",
		eventBody: "ec-event-body workshop-calendar-event-body",
		highlight: "ec-highlight tr-holiday-day",
	}),
});
</script>

<div class="grid gap-6 lg:grid-cols-[19rem_minmax(0,1fr)]">
	<!-- Rail -->
	<aside class="space-y-3 lg:sticky lg:top-6 lg:self-start">
		<div class="flex items-center justify-between">
			<div>
				<p class="text-xs font-bold tracking-[0.18em] text-primary uppercase">
					Training
				</p>
				<h1 class="text-2xl font-bold tracking-tight">Trainings</h1>
			</div>
			<Button size="sm" onclick={openCreate}
				><Plus aria-hidden="true" /> Add</Button
			>
		</div>
		<ul class="space-y-2">
			{#each store.trainings as training (training.id)}
				{@const next = upcomingOccurrences(training, 1)[0]}
				<li>
					<button
						type="button"
						class="w-full cursor-pointer rounded-2xl border p-3 text-left transition-colors hover:border-primary/50 {selected?.id ===
						training.id
							? 'border-primary bg-primary/6'
							: ''}"
						class:opacity-60={!training.enabled}
						onclick={() => {
							selectedId = training.id;
							focusKey = null;
						}}
					>
						<div class="flex items-start justify-between gap-2">
							<span class="min-w-0">
								<span
									class="block text-[0.6875rem] font-bold tracking-[0.12em] text-muted-foreground uppercase"
									>{KIND_LABEL[training.kind]}{training.schedule.type ===
									"one_off"
										? " · one-off"
										: ""}</span
								>
								<span class="block truncate font-bold">{training.title}</span>
								<span class="block text-xs text-muted-foreground"
									>{scheduleLabel(training)}</span
								>
							</span>
							<span
								class="tr-dot tr-dot--{training.enabled
									? next
										? statusOf(next)
										: 'default'
									: 'disabled'} mt-1.5"
							></span>
						</div>
						{#if next}
							<p class="mt-2 text-xs text-muted-foreground">
								Next: {formatLongDate(next.date)} —
								<span class="font-semibold text-foreground"
									>{next.willPost
										? "posts"
										: decisionLabel(
												next.decision,
												next.holiday,
											).toLowerCase()}</span
								>
							</p>
						{:else}
							<p class="mt-2 text-xs text-muted-foreground">
								No upcoming dates
							</p>
						{/if}
					</button>
				</li>
			{/each}
		</ul>
	</aside>

	<!-- Detail -->
	{#if selected}
		<section class="space-y-5">
			<header
				class="flex flex-col gap-3 rounded-2xl border border-border/80 bg-card p-5 sm:flex-row sm:items-start sm:justify-between"
			>
				<div class="min-w-0 space-y-1">
					<p
						class="text-xs font-bold tracking-[0.14em] text-muted-foreground uppercase"
					>
						{KIND_LABEL[selected.kind]} → {CHANNEL[selected.kind]}
					</p>
					<h2 class="truncate text-2xl font-bold">{selected.title}</h2>
					<p class="text-sm text-muted-foreground">
						{scheduleLabel(selected)} · Europe/Dublin{selected.everyone
							? " · pings @everyone"
							: " · no ping"}
					</p>
				</div>
				<div class="flex flex-wrap items-center gap-2">
					<label
						class="flex cursor-pointer items-center gap-2 rounded-xl border px-3 py-2 text-sm font-semibold"
					>
						{selected.enabled ? "Enabled" : "Disabled"}
						<Switch
							checked={selected.enabled}
							onCheckedChange={(v) => store.setEnabled(selected.id, v)}
						/>
					</label>
					<Button variant="outline" onclick={() => openEdit(selected)}
						><Pencil aria-hidden="true" /> Edit</Button
					>
					{#if selected.attempted}
						<Button
							variant="ghost"
							class="text-muted-foreground"
							onclick={() => store.setEnabled(selected.id, false)}
							>Retire</Button
						>
					{:else}
						<Button
							variant="ghost"
							class="text-destructive"
							onclick={() => {
								store.remove(selected.id);
								selectedId = store.trainings[0]?.id ?? "";
							}}><Trash2 aria-hidden="true" /> Delete</Button
						>
					{/if}
				</div>
			</header>

			{#if collisions.length > 0}
				<p
					class="flex items-start gap-2 rounded-xl border border-secondary/60 bg-secondary/10 px-3 py-2 text-sm"
				>
					<AlertTriangle
						aria-hidden="true"
						class="mt-0.5 size-4 flex-none text-secondary"
					/>
					{collisions.length} time slot{collisions.length === 1 ? "" : "s"} this week
					with more than one post at the same minute. Allowed, but worth a look.
				</p>
			{/if}

			<div
				class="workshop-calendar-container overflow-hidden rounded-2xl border border-border/80 bg-card shadow-sm"
			>
				<Calendar plugins={[TimeGrid, Interaction]} {options} />
			</div>

			{#if focused}
				{@const status = statusOf(focused)}
				<div
					class="grid gap-4 rounded-2xl border border-primary/40 bg-card p-5 md:grid-cols-[minmax(0,1fr)_minmax(0,22rem)]"
				>
					<div class="space-y-2">
						<div class="flex items-start justify-between gap-2">
							<div>
								<p
									class="text-xs font-bold tracking-[0.14em] text-primary uppercase"
								>
									{formatLongDate(focused.date)} · {focused.startTime}
								</p>
								<h3 class="flex flex-wrap items-center gap-2 text-xl font-bold">
									{focused.title}
									<span class="tr-pill tr-pill--{status}"
										>{STATUS_LABEL[status] ?? status}</span
									>
								</h3>
							</div>
							<Button
								variant="ghost"
								size="icon"
								aria-label="Close occurrence"
								onclick={() => (focusKey = null)}
								><X aria-hidden="true" /></Button
							>
						</div>
						<p class="text-sm text-muted-foreground">
							{#if focused.past && focused.delivery}
								{DELIVERY_LABEL[focused.delivery.state]}{focused.delivery.reason
									? ` — ${focused.delivery.reason}`
									: ""}.
							{:else if focused.willPost}
								Resolved from {decisionLabel(focused.decision).toLowerCase()}.
								Posts at {focused.startTime}; the copy freezes then.
							{:else}
								Nothing posts — {decisionLabel(
									focused.decision,
									focused.holiday,
								).toLowerCase()}.
							{/if}
						</p>
						{#if !focused.past && focused.decision !== "bank_holiday" && focused.decision !== "disabled"}
							<div class="flex flex-wrap gap-2 pt-1">
								{#if focused.suppression}
									<Button
										size="sm"
										variant="outline"
										onclick={() => store.unsuppress(focused.suppression!.id)}
										>Remove suppression</Button
									>
								{:else}
									<Button
										size="sm"
										variant="outline"
										onclick={() => openSuppress(focused.date)}
										><CalendarOff aria-hidden="true" /> Skip this date</Button
									>
								{/if}
								{#if !focused.override}
									<Button
										size="sm"
										variant="outline"
										onclick={() => openOverride(focused.date)}
										><Pencil aria-hidden="true" /> Change copy for this date</Button
									>
								{/if}
							</div>
						{/if}
					</div>
					<DiscordPreview
						channel={CHANNEL[focused.training.kind]}
						rendered={focused.rendered}
						threadName={focused.threadName}
						muted={!focused.willPost}
						compact
					/>
				</div>
			{/if}

			<div class="grid gap-4 xl:grid-cols-2">
				<!-- Exceptions -->
				<div class="self-start rounded-2xl border border-border/80 bg-card p-5">
					<div class="mb-3 flex items-center justify-between">
						<h3 class="font-bold">Exceptions</h3>
						<div class="flex gap-1.5">
							<Button size="sm" variant="outline" onclick={() => openSuppress()}
								><CalendarOff aria-hidden="true" /> Skip dates</Button
							>
							<Button size="sm" variant="outline" onclick={() => openOverride()}
								><Pencil aria-hidden="true" /> Change copy</Button
							>
						</div>
					</div>
					{#if store.suppressionsFor(selected.id).length === 0 && store.overridesFor(selected.id).length === 0}
						<p class="text-sm text-muted-foreground">
							No skipped dates or copy changes. Bank holidays are skipped
							automatically.
						</p>
					{/if}
					<ul class="divide-y">
						{#each store.suppressionsFor(selected.id) as s (s.id)}
							<li class="flex items-center justify-between gap-3 py-2.5">
								<div class="flex min-w-0 items-center gap-3">
									<span class="tr-pill tr-pill--suppressed">Skip</span>
									<span class="min-w-0"
										><span class="block text-sm font-semibold"
											>{formatRange(s.from, s.to)}</span
										>{#if s.note}<span
												class="block truncate text-xs text-muted-foreground"
												>{s.note}</span
											>{/if}</span
									>
								</div>
								<Button
									size="icon"
									variant="ghost"
									aria-label="Remove"
									disabled={s.to < TODAY}
									onclick={() => store.unsuppress(s.id)}
									><Trash2 aria-hidden="true" /></Button
								>
							</li>
						{/each}
						{#each store.overridesFor(selected.id) as o (o.id)}
							<li class="flex items-center justify-between gap-3 py-2.5">
								<div class="flex min-w-0 items-center gap-3">
									<span class="tr-pill tr-pill--overridden">Copy</span>
									<span class="min-w-0"
										><span class="block text-sm font-semibold"
											>{formatRange(o.from, o.to)}</span
										><span class="block truncate text-xs text-muted-foreground"
											>{o.title ?? "Default title"} — {o.message ??
												"default message"}</span
										></span
									>
								</div>
								<Button
									size="icon"
									variant="ghost"
									aria-label="Remove"
									disabled={o.to < TODAY}
									onclick={() => store.removeOverride(o.id)}
									><Trash2 aria-hidden="true" /></Button
								>
							</li>
						{/each}
					</ul>
				</div>

				<!-- Upcoming + recent -->
				<div class="rounded-2xl border border-border/80 bg-card p-5">
					<h3 class="mb-3 font-bold">Next posts</h3>
					<ul class="divide-y">
						{#each upcoming.slice(0, 5) as o (o.key)}
							{@const status = statusOf(o)}
							<li class="flex items-center justify-between gap-3 py-2">
								<button
									type="button"
									class="min-w-0 flex-1 cursor-pointer text-left text-sm hover:text-primary"
									onclick={() => (focusKey = o.key)}
								>
									<span
										class="block font-semibold"
										class:line-through={!o.willPost}
										class:text-muted-foreground={!o.willPost}
										>{formatLongDate(o.date)} · {o.startTime}</span
									>
									<span class="block truncate text-xs text-muted-foreground"
										>{o.title}</span
									>
								</button>
								<span class="tr-pill tr-pill--{status}"
									>{STATUS_LABEL[status] ?? status}</span
								>
							</li>
						{/each}
					</ul>
					<h3 class="mt-5 mb-3 font-bold">Recent deliveries</h3>
					<ul class="divide-y">
						{#each recent.slice(0, 4) as o (o.key)}
							{@const status = statusOf(o)}
							<li class="flex items-center justify-between gap-3 py-2 text-sm">
								<span class="min-w-0">
									<span class="block font-semibold"
										>{formatLongDate(o.date)}</span
									>
									<span class="block truncate text-xs text-muted-foreground"
										>{o.delivery?.reason ??
											(o.delivery?.messageId
												? `message ${o.delivery.messageId}`
												: "")}</span
									>
								</span>
								<span class="tr-pill tr-pill--{status}"
									>{STATUS_LABEL[status] ?? status}</span
								>
							</li>
						{/each}
					</ul>
				</div>
			</div>
		</section>
	{/if}
</div>

<Sheet.Root
	open={sheet !== null}
	onOpenChange={(open) => {
		if (!open) sheet = null;
	}}
>
	<Sheet.Content side="right" class="w-full overflow-y-auto sm:max-w-2xl">
		{#if sheet?.kind === "training"}
			<Sheet.Header>
				<Sheet.Title
					>{sheet.editingId ? "Edit Training" : "Add Training"}</Sheet.Title
				>
				<Sheet.Description
					>{sheet.editingId
						? "Applies from today. Frozen deliveries keep their snapshot."
						: "Weekly posts every week until disabled; one-off posts once."}</Sheet.Description
				>
			</Sheet.Header>
			<div class="px-4">
				<TrainingFormFields
					bind:draft
					kindLocked={sheet.editingId !== null}
					idPrefix="b"
				/>
			</div>
			<Sheet.Footer>
				<Button variant="ghost" onclick={() => (sheet = null)}>Cancel</Button>
				<Button onclick={saveTraining}
					>{sheet.editingId ? "Save changes" : "Create Training"}</Button
				>
			</Sheet.Footer>
		{:else if sheet?.kind === "suppress" && selected}
			<Sheet.Header>
				<Sheet.Title>Skip dates for {selected.title}</Sheet.Title>
				<Sheet.Description
					>Nothing posts on these dates. Leave a note so the next committee
					knows why.</Sheet.Description
				>
			</Sheet.Header>
			<div class="space-y-3 px-4">
				<div class="grid gap-3 sm:grid-cols-2">
					<div class="space-y-1.5">
						<Label for="b-sup-from">From</Label><Input
							id="b-sup-from"
							type="date"
							min={TODAY}
							bind:value={sheet.from}
						/>
					</div>
					<div class="space-y-1.5">
						<Label for="b-sup-to">To</Label><Input
							id="b-sup-to"
							type="date"
							min={sheet.from}
							bind:value={sheet.to}
						/>
					</div>
				</div>
				<div class="space-y-1.5">
					<Label for="b-sup-note">Note</Label><Input
						id="b-sup-note"
						bind:value={sheet.note}
						placeholder="Winter break"
					/>
				</div>
				<p class="text-xs text-muted-foreground">
					Affects {suppressAffected} upcoming post(s).
				</p>
			</div>
			<Sheet.Footer>
				<Button variant="ghost" onclick={() => (sheet = null)}>Cancel</Button>
				<Button onclick={saveException}>Skip these dates</Button>
			</Sheet.Footer>
		{:else if sheet?.kind === "override" && selected}
			<Sheet.Header>
				<Sheet.Title>Change copy for {selected.title}</Sheet.Title>
				<Sheet.Description
					>Only title and message change. Ranges for one Training cannot
					overlap.</Sheet.Description
				>
			</Sheet.Header>
			<div class="space-y-3 px-4">
				<div class="grid gap-3 sm:grid-cols-2">
					<div class="space-y-1.5">
						<Label for="b-ov-from">From</Label><Input
							id="b-ov-from"
							type="date"
							min={TODAY}
							bind:value={sheet.from}
						/>
					</div>
					<div class="space-y-1.5">
						<Label for="b-ov-to">To</Label><Input
							id="b-ov-to"
							type="date"
							min={sheet.from}
							bind:value={sheet.to}
						/>
					</div>
				</div>
				<div class="space-y-1.5">
					<Label for="b-ov-title">Title</Label><Input
						id="b-ov-title"
						bind:value={sheet.title}
						maxlength={100}
					/>
				</div>
				<div class="space-y-1.5">
					<Label for="b-ov-message">Message</Label><Textarea
						id="b-ov-message"
						rows={4}
						bind:value={sheet.message}
					/>
				</div>
				{#if sheet.error}<p class="text-sm font-semibold text-destructive">
						{sheet.error}
					</p>{/if}
				{#if overridePreview}
					<p
						class="text-xs font-bold tracking-[0.14em] text-muted-foreground uppercase"
					>
						Preview · {formatLongDate(overridePreview.date)}
					</p>
					<DiscordPreview
						channel={CHANNEL[selected.kind]}
						rendered={overridePreview.rendered}
						threadName={overridePreview.threadName}
						compact
					/>
				{/if}
			</div>
			<Sheet.Footer>
				<Button variant="ghost" onclick={() => (sheet = null)}>Cancel</Button>
				<Button onclick={saveException}>Save override</Button>
			</Sheet.Footer>
		{/if}
	</Sheet.Content>
</Sheet.Root>

<style>
:global(.tr-calendar .tr-holiday-day) {
	background: repeating-linear-gradient(
		-45deg,
		hsl(var(--destructive) / 0.06) 0 6px,
		transparent 6px 12px
	);
}

:global(.tr-week .ec-time),
:global(.tr-week .ec-line) {
	color: hsl(var(--muted-foreground));
	font-size: 0.6875rem;
}

:global(.tr-week .workshop-calendar-body .workshop-calendar-day) {
	min-height: 0;
}

:global(.tr-week .tr-week-dim) {
	opacity: 0.35;
}

:global(.tr-week .workshop-calendar-event) {
	margin: 0 0.15rem;
}

:global(.tr-week .tr-event--compact) {
	display: flex;
	height: 100%;
	align-items: center;
	gap: 0.35rem;
	overflow: hidden;
	padding: 0 0.4rem;
	white-space: nowrap;
}

:global(.tr-week .tr-event--compact time) {
	flex: none;
	color: hsl(var(--muted-foreground));
	font-size: 0.6875rem;
	font-weight: 800;
	font-variant-numeric: tabular-nums;
}

:global(.tr-week .tr-event--compact .tr-event-title) {
	display: block;
	overflow: hidden;
	margin: 0;
	text-overflow: ellipsis;
	line-clamp: unset;
	-webkit-line-clamp: unset;
}
</style>
