<!--
	PROTOTYPE — throwaway. Variant A — "Calendar-first, occurrence inspector".
	The month grid IS the page. Every Training Occurrence is a chip whose colour is
	its resolved status; click one to inspect the precedence chain, the rendered
	message and delivery evidence, and act on that date. Drag across days to
	suppress a range. Trainings themselves live in a compact strip under the grid.
-->
<script lang="ts">
import { Calendar, DayGrid, Interaction } from "@event-calendar/core";
import "@event-calendar/core/index.css";
import { Button } from "$lib/components/ui/button";
import * as Dialog from "$lib/components/ui/dialog";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import { Switch } from "$lib/components/ui/switch";
import { Textarea } from "$lib/components/ui/textarea";
import dayjs from "dayjs";
import {
	Ban,
	CalendarOff,
	Check,
	ExternalLink,
	Pencil,
	Plus,
	Trash2,
} from "@lucide/svelte";
import DiscordPreview from "./discord-preview.svelte";
import TrainingFormFields from "./training-form-fields.svelte";
import {
	ANNOUNCEMENT_CHANNEL,
	CHANNEL,
	DELIVERY_LABEL,
	HOLIDAYS,
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

// --- calendar range → events ------------------------------------------------
let range = $state({
	start: dayjs(TODAY).startOf("month").subtract(7, "day").toDate(),
	end: dayjs(TODAY).endOf("month").add(14, "day").toDate(),
});
const occurrences = $derived(occurrencesBetween(range.start, range.end));
const announcements = $derived(announcementsBetween(range.start, range.end));
const byKey = $derived(new Map(occurrences.map((o) => [o.key, o])));

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

// --- inspector ----------------------------------------------------------------
let inspectorKey = $state<string | null>(null);
const inspected = $derived(
	inspectorKey ? (byKey.get(inspectorKey) ?? null) : null,
);
let inspectorOpen = $state(false);

// --- exception editors ----------------------------------------------------------
let suppressDraft = $state<{
	trainingIds: string[];
	from: string;
	to: string;
	note: string;
} | null>(null);
let overrideDraft = $state<{
	trainingId: string;
	from: string;
	to: string;
	title: string;
	message: string;
	error: string;
} | null>(null);

// --- training editor -----------------------------------------------------------
let editorOpen = $state(false);
let editingId = $state<string | null>(null);
let draft = $state<TrainingDraft>(emptyDraft());

function openCreate() {
	editingId = null;
	draft = emptyDraft();
	editorOpen = true;
}

function openEdit(training: Training) {
	editingId = training.id;
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
	inspectorOpen = false;
	editorOpen = true;
}

function saveTraining() {
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
	if (editingId) {
		store.update(editingId, {
			title: draft.title,
			message: draft.message,
			everyone: draft.everyone,
			schedule,
		});
	} else {
		store.add({
			kind: draft.kind,
			title: draft.title,
			message: draft.message,
			everyone: draft.everyone,
			enabled: true,
			schedule,
		});
	}
	editorOpen = false;
}

// --- calendar options -------------------------------------------------------------
const options = $derived({
	view: "dayGridMonth",
	date: TODAY,
	events,
	headerToolbar: { start: "title", center: "", end: "today prev,next" },
	buttonText: { today: "Today" },
	height: "auto",
	firstDay: 1 as const,
	highlightedDates: HOLIDAYS.map((h) => h.date),
	selectable: true,
	select: (info: { startStr: string; endStr: string }) => {
		const from = info.startStr.slice(0, 10);
		const to = dayjs(info.endStr).subtract(1, "day").format("YYYY-MM-DD");
		if (to < TODAY) return;
		suppressDraft = {
			trainingIds: store.trainings
				.filter((t) => t.schedule.type === "weekly")
				.map((t) => t.id),
			from: from < TODAY ? TODAY : from,
			to,
			note: "",
		};
	},
	datesSet: (info: { start: Date; end: Date }) => {
		// Only write when the window moved; a fresh object every call re-renders the calendar forever.
		if (
			range.start.getTime() === info.start.getTime() &&
			range.end.getTime() === info.end.getTime()
		)
			return;
		range = { start: info.start, end: info.end };
	},
	eventClick: (info: {
		event: { id: string | number; extendedProps: { type?: string } };
	}) => {
		if (info.event.extendedProps.type !== "occurrence") return;
		inspectorKey = String(info.event.id);
		inspectorOpen = true;
	},
	eventContent: (info: Calendar.EventContentInfo) => {
		if (info.event.extendedProps.type === "announcement") {
			const a = announcements.find((x) => x.key === String(info.event.id));
			if (!a) return { html: "" };
			return {
				html: `<div class="tr-event tr-event--announcement" title="Bank holiday announcement">
					<div class="tr-event-meta"><span>${a.phase === "day_before" ? "Day before" : "Same day"} · ${ANNOUNCEMENT_CHANNEL}</span><time>09:00</time></div>
					<div class="tr-event-title">${escapeHtml(a.holiday.name)}</div>
				</div>`,
			};
		}
		const o = byKey.get(String(info.event.id));
		if (!o) return { html: "" };
		const status = statusOf(o);
		const struck = !o.willPost && !o.past;
		return {
			html: `<div class="tr-event tr-event--${status}${struck ? " tr-event--struck" : ""}" title="${escapeHtml(o.title)}">
				<div class="tr-event-meta">
					<span class="tr-event-status"><span class="tr-event-dot"></span>${escapeHtml(STATUS_LABEL[status] ?? status)}</span>
					<time>${o.startTime}</time>
				</div>
				<div class="tr-event-title">${escapeHtml(o.title)}</div>
				<div class="tr-event-footer"><span>${KIND_LABEL[o.training.kind]}${o.training.everyone ? " · @everyone" : ""}</span>${o.training.schedule.type === "one_off" ? '<span class="tr-marker">One-off</span>' : ""}</div>
			</div>`,
		};
	},
	dayMaxEvents: true,
	moreLinkContent: (arg: { num: number }) => `+${arg.num} more`,
	theme: (t: Record<string, string | string[]>) => ({
		...t,
		calendar: "ec workshop-calendar tr-calendar",
		header: "ec-header workshop-calendar-weekdays",
		toolbar: "ec-toolbar workshop-calendar-toolbar",
		button: "ec-button workshop-calendar-control",
		buttonGroup: "ec-button-group workshop-calendar-control-group",
		title: "ec-title workshop-calendar-title",
		body: "ec-body workshop-calendar-body",
		dayHead: "ec-day-head workshop-calendar-day-number",
		day: "ec-day workshop-calendar-day",
		today: "ec-today workshop-calendar-today",
		otherMonth: "ec-other-month workshop-calendar-other-month",
		event: "ec-event workshop-calendar-event",
		eventBody: "ec-event-body workshop-calendar-event-body",
		popup: "ec-popup workshop-calendar-popup",
		highlight: "ec-highlight tr-holiday-day",
	}),
});

const PRECEDENCE = [
	{
		id: "bank_holiday",
		label: "Irish bank holiday",
		note: "Cannot be overridden",
	},
	{ id: "disabled", label: "Training disabled" },
	{ id: "suppressed", label: "Training Suppression" },
	{ id: "overridden", label: "Training Override" },
	{ id: "default", label: "Training defaults" },
] as const;

function precedenceState(
	o: Occurrence,
	step: (typeof PRECEDENCE)[number]["id"],
) {
	const order = PRECEDENCE.map((p) => p.id);
	const winner = order.indexOf(o.decision);
	const index = order.indexOf(step);
	if (index === winner) return "won";
	if (index < winner) return "passed";
	// A later rule that would have applied had the winner not.
	if (step === "overridden" && o.override) return "shadowed";
	if (step === "suppressed" && o.suppression) return "shadowed";
	return "unreached";
}

function startOverride(o: Occurrence) {
	overrideDraft = {
		trainingId: o.training.id,
		from: o.date,
		to: o.date,
		title: o.training.title,
		message: o.training.message,
		error: "",
	};
	inspectorOpen = false;
}

function startSuppress(o: Occurrence) {
	suppressDraft = {
		trainingIds: [o.training.id],
		from: o.date,
		to: o.date,
		note: "",
	};
	inspectorOpen = false;
}

function saveSuppression() {
	if (!suppressDraft) return;
	for (const trainingId of suppressDraft.trainingIds) {
		store.suppress({
			trainingId,
			from: suppressDraft.from,
			to: suppressDraft.to,
			note: suppressDraft.note || undefined,
		});
	}
	suppressDraft = null;
}

function saveOverride() {
	if (!overrideDraft) return;
	const result = store.override({
		trainingId: overrideDraft.trainingId,
		from: overrideDraft.from,
		to: overrideDraft.to,
		title: overrideDraft.title,
		message: overrideDraft.message,
	});
	if (!result.ok) {
		overrideDraft.error = result.error;
		return;
	}
	overrideDraft = null;
}

const overridePreview = $derived.by(() => {
	if (!overrideDraft) return null;
	const training = store.get(overrideDraft.trainingId);
	if (!training) return null;
	const probe: Training = {
		...training,
		title: overrideDraft.title,
		message: overrideDraft.message,
	};
	return resolveOccurrence(probe, overrideDraft.from);
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
				Discord training schedule
			</h1>
			<p class="text-base leading-7 text-muted-foreground">
				Every chip is one post the club bot will make. Click a chip to see
				exactly what goes out and why; drag across days to skip a stretch.
			</p>
		</div>
		<Button onclick={openCreate}>
			<Plus aria-hidden="true" />
			Add Training
		</Button>
	</header>

	<div
		class="workshop-calendar-container overflow-hidden rounded-2xl border border-border/80 bg-card shadow-sm"
	>
		<Calendar plugins={[DayGrid, Interaction]} {options} />

		<div
			class="flex flex-col gap-3 border-t border-border/70 bg-muted/20 px-5 py-4 xl:flex-row xl:items-center xl:justify-between"
		>
			<p class="text-sm font-medium">
				<span class="font-bold tabular-nums"
					>{occurrences.filter((o) => !o.past && o.willPost).length}</span
				>
				posts scheduled in view ·
				<span class="font-bold tabular-nums"
					>{occurrences.filter((o) => !o.past && !o.willPost).length}</span
				>
				skipped
			</p>
			<div
				class="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs font-semibold text-muted-foreground"
				aria-label="Status key"
			>
				{#each [["default", "Scheduled"], ["overridden", "Override copy"], ["suppressed", "Suppressed"], ["bank_holiday", "Bank holiday"], ["disabled", "Disabled"], ["delivered", "Delivered"], ["thread_failed", "Thread failed"], ["message_uncertain", "Uncertain"], ["blocked", "Blocked"], ["missed", "Missed"]] as [status, label] (status)}
					<span class="flex items-center gap-1.5"
						><span class="tr-dot tr-dot--{status}"></span>{label}</span
					>
				{/each}
			</div>
		</div>
	</div>

	<section
		aria-label="Trainings"
		class="grid gap-3 md:grid-cols-2 xl:grid-cols-4"
	>
		{#each store.trainings as training (training.id)}
			<div
				class="flex flex-col gap-2 rounded-2xl border border-border/80 bg-card p-4"
				class:opacity-60={!training.enabled}
			>
				<div class="flex items-start justify-between gap-2">
					<div class="min-w-0">
						<p
							class="text-[0.6875rem] font-bold tracking-[0.12em] text-muted-foreground uppercase"
						>
							{KIND_LABEL[training.kind]} · {CHANNEL[training.kind]}
						</p>
						<p class="truncate font-bold">{training.title}</p>
						<p class="text-xs text-muted-foreground">
							{scheduleLabel(training)}
						</p>
					</div>
					<label
						class="flex cursor-pointer items-center gap-2 text-xs font-semibold"
					>
						<span class="sr-only">Enabled</span>
						<Switch
							checked={training.enabled}
							onCheckedChange={(v) => store.setEnabled(training.id, v)}
						/>
					</label>
				</div>
				<div
					class="flex flex-wrap gap-1.5 text-[0.6875rem] font-semibold text-muted-foreground"
				>
					<span class="rounded-full border px-2 py-0.5"
						>{store.suppressionsFor(training.id).length} suppressions</span
					>
					<span class="rounded-full border px-2 py-0.5"
						>{store.overridesFor(training.id).length} overrides</span
					>
					{#if training.everyone}<span class="rounded-full border px-2 py-0.5"
							>@everyone</span
						>{/if}
				</div>
				<div class="mt-auto flex gap-2">
					<Button
						variant="outline"
						size="sm"
						onclick={() => openEdit(training)}
					>
						<Pencil aria-hidden="true" /> Edit
					</Button>
					{#if training.attempted}
						<Button
							variant="ghost"
							size="sm"
							class="text-muted-foreground"
							onclick={() => store.setEnabled(training.id, false)}
						>
							<Ban aria-hidden="true" /> Retire
						</Button>
					{:else}
						<Button
							variant="ghost"
							size="sm"
							class="text-destructive"
							onclick={() => store.remove(training.id)}
						>
							<Trash2 aria-hidden="true" /> Delete
						</Button>
					{/if}
				</div>
			</div>
		{/each}
	</section>
</div>

<!-- Occurrence inspector -->
<Dialog.Root bind:open={inspectorOpen}>
	<Dialog.Content
		class="max-h-[calc(100dvh-2rem)] overflow-y-auto sm:max-w-3xl"
	>
		{#if inspected}
			{@const status = statusOf(inspected)}
			<Dialog.Header>
				<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
					{KIND_LABEL[inspected.training.kind]} · {formatLongDate(
						inspected.date,
					)} · {inspected.startTime} · {CHANNEL[inspected.training.kind]}
				</p>
				<Dialog.Title class="flex flex-wrap items-center gap-2 text-2xl">
					{inspected.title}
					<span class="tr-pill tr-pill--{status}"
						>{STATUS_LABEL[status] ?? status}</span
					>
				</Dialog.Title>
				<Dialog.Description>
					{#if inspected.past && inspected.delivery}
						{DELIVERY_LABEL[inspected.delivery.state]}
						{#if inspected.delivery.at}at {dayjs(inspected.delivery.at).format(
								"HH:mm:ss",
							)}{/if}
						{#if inspected.delivery.reason}
							— {inspected.delivery.reason}{/if}
					{:else if inspected.willPost}
						Will post at {inspected.startTime} Europe/Dublin. Snapshot freezes at
						that moment; edits after it affect later dates only.
					{:else}
						Nothing will post on this date — {decisionLabel(
							inspected.decision,
							inspected.holiday,
						).toLowerCase()}.
					{/if}
				</Dialog.Description>
			</Dialog.Header>

			<div class="grid gap-5 md:grid-cols-[minmax(0,15rem)_minmax(0,1fr)]">
				<div>
					<p
						class="mb-2 text-xs font-bold tracking-[0.14em] text-muted-foreground uppercase"
					>
						Why this outcome
					</p>
					<ol class="space-y-1">
						{#each PRECEDENCE as step (step.id)}
							{@const state = precedenceState(inspected, step.id)}
							<li class="tr-rule tr-rule--{state}">
								<span class="tr-rule-mark" aria-hidden="true">
									{#if state === "won"}<Check
											class="size-3.5"
										/>{:else if state === "passed"}—{:else}·{/if}
								</span>
								<span class="min-w-0">
									<span class="block text-sm font-semibold">{step.label}</span>
									{#if state === "won" && step.id === "suppressed" && inspected.suppression}
										<span class="block text-xs text-muted-foreground"
											>{formatRange(
												inspected.suppression.from,
												inspected.suppression.to,
											)}{inspected.suppression.note
												? ` · ${inspected.suppression.note}`
												: ""}</span
										>
									{:else if (state === "won" || state === "shadowed") && step.id === "overridden" && inspected.override}
										<span class="block text-xs text-muted-foreground"
											>{formatRange(
												inspected.override.from,
												inspected.override.to,
											)}{state === "shadowed"
												? " · stored, not applied"
												: ""}</span
										>
									{:else if state === "won" && step.id === "bank_holiday" && inspected.holiday}
										<span class="block text-xs text-muted-foreground"
											>{inspected.holiday.name}{"note" in step
												? ` · ${step.note}`
												: ""}</span
										>
									{/if}
								</span>
							</li>
						{/each}
					</ol>
				</div>
				<div class="space-y-3">
					<p
						class="text-xs font-bold tracking-[0.14em] text-muted-foreground uppercase"
					>
						{inspected.past ? "What was posted" : "What will post"}
					</p>
					<DiscordPreview
						channel={CHANNEL[inspected.training.kind]}
						rendered={inspected.rendered}
						threadName={inspected.threadName}
						muted={!inspected.willPost}
					/>
					{#if inspected.past && inspected.delivery && inspected.delivery.messageId}
						<dl class="grid grid-cols-2 gap-2 text-xs">
							<div class="rounded-lg border px-3 py-2">
								<dt class="text-muted-foreground">Message id</dt>
								<dd class="font-mono">{inspected.delivery.messageId}</dd>
							</div>
							<div class="rounded-lg border px-3 py-2">
								<dt class="text-muted-foreground">Thread id</dt>
								<dd class="font-mono">
									{inspected.delivery.threadId ?? "— none"}
								</dd>
							</div>
						</dl>
					{/if}
				</div>
			</div>

			<Dialog.Footer class="flex-wrap gap-2 sm:justify-between">
				<div class="flex flex-wrap gap-2">
					{#if !inspected.past && inspected.decision !== "bank_holiday"}
						{#if inspected.suppression}
							<Button
								variant="outline"
								onclick={() => {
									store.unsuppress(inspected.suppression!.id);
								}}
							>
								<CalendarOff aria-hidden="true" /> Remove suppression
							</Button>
						{:else if inspected.decision !== "disabled"}
							<Button
								variant="outline"
								onclick={() => startSuppress(inspected)}
							>
								<CalendarOff aria-hidden="true" /> Skip this date
							</Button>
						{/if}
						{#if inspected.override}
							<Button
								variant="outline"
								onclick={() => {
									store.removeOverride(inspected.override!.id);
								}}
							>
								Remove override
							</Button>
						{:else}
							<Button
								variant="outline"
								onclick={() => startOverride(inspected)}
							>
								<Pencil aria-hidden="true" /> Change copy for this date
							</Button>
						{/if}
					{/if}
					{#if inspected.past && inspected.delivery?.messageId}
						<Button variant="ghost" class="text-muted-foreground"
							><ExternalLink aria-hidden="true" /> Open in Discord</Button
						>
					{/if}
				</div>
				<Button variant="ghost" onclick={() => openEdit(inspected.training)}
					>Edit Training defaults</Button
				>
			</Dialog.Footer>
		{/if}
	</Dialog.Content>
</Dialog.Root>

<!-- Suppress range -->
<Dialog.Root
	open={suppressDraft !== null}
	onOpenChange={(open) => {
		if (!open) suppressDraft = null;
	}}
>
	<Dialog.Content>
		{#if suppressDraft}
			<Dialog.Header>
				<Dialog.Title
					>Skip {formatRange(
						suppressDraft.from,
						suppressDraft.to,
					)}</Dialog.Title
				>
				<Dialog.Description
					>Nothing posts for the chosen Trainings on these dates. Dates already
					delivered are never rewritten.</Dialog.Description
				>
			</Dialog.Header>
			<div class="grid gap-3 sm:grid-cols-2">
				<div class="space-y-1.5">
					<Label for="a-sup-from">From</Label><Input
						id="a-sup-from"
						type="date"
						min={TODAY}
						bind:value={suppressDraft.from}
					/>
				</div>
				<div class="space-y-1.5">
					<Label for="a-sup-to">To</Label><Input
						id="a-sup-to"
						type="date"
						min={suppressDraft.from}
						bind:value={suppressDraft.to}
					/>
				</div>
			</div>
			<fieldset class="space-y-1.5">
				<legend class="text-sm font-semibold">Trainings affected</legend>
				{#each store.trainings.filter((t) => t.schedule.type === "weekly") as training (training.id)}
					<label class="flex cursor-pointer items-center gap-2 text-sm">
						<input
							type="checkbox"
							class="accent-primary"
							value={training.id}
							bind:group={suppressDraft.trainingIds}
						/>
						{training.title}
						<span class="text-xs text-muted-foreground"
							>· {scheduleLabel(training)}</span
						>
					</label>
				{/each}
			</fieldset>
			<div class="space-y-1.5">
				<Label for="a-sup-note">Note (optional)</Label><Input
					id="a-sup-note"
					bind:value={suppressDraft.note}
					placeholder="Hall closed for the AGM"
				/>
			</div>
			<Dialog.Footer>
				<Button variant="ghost" onclick={() => (suppressDraft = null)}
					>Cancel</Button
				>
				<Button
					onclick={saveSuppression}
					disabled={suppressDraft.trainingIds.length === 0}
					>Skip these dates</Button
				>
			</Dialog.Footer>
		{/if}
	</Dialog.Content>
</Dialog.Root>

<!-- Override -->
<Dialog.Root
	open={overrideDraft !== null}
	onOpenChange={(open) => {
		if (!open) overrideDraft = null;
	}}
>
	<Dialog.Content
		class="max-h-[calc(100dvh-2rem)] overflow-y-auto sm:max-w-3xl"
	>
		{#if overrideDraft}
			<Dialog.Header>
				<Dialog.Title
					>Change the copy for {formatRange(
						overrideDraft.from,
						overrideDraft.to,
					)}</Dialog.Title
				>
				<Dialog.Description
					>Replaces the title and/or message on these dates only. Kind, channel,
					time and @everyone stay as the Training defines them.</Dialog.Description
				>
			</Dialog.Header>
			<div class="grid gap-5 md:grid-cols-[minmax(0,1fr)_minmax(0,20rem)]">
				<div class="space-y-3">
					<div class="grid gap-3 sm:grid-cols-2">
						<div class="space-y-1.5">
							<Label for="a-ov-from">From</Label><Input
								id="a-ov-from"
								type="date"
								min={TODAY}
								bind:value={overrideDraft.from}
							/>
						</div>
						<div class="space-y-1.5">
							<Label for="a-ov-to">To</Label><Input
								id="a-ov-to"
								type="date"
								min={overrideDraft.from}
								bind:value={overrideDraft.to}
							/>
						</div>
					</div>
					<div class="space-y-1.5">
						<Label for="a-ov-title">Title</Label><Input
							id="a-ov-title"
							bind:value={overrideDraft.title}
							maxlength={100}
						/>
					</div>
					<div class="space-y-1.5">
						<Label for="a-ov-message">Message</Label><Textarea
							id="a-ov-message"
							rows={4}
							bind:value={overrideDraft.message}
						/>
					</div>
					{#if overrideDraft.error}<p
							class="text-sm font-semibold text-destructive"
						>
							{overrideDraft.error}
						</p>{/if}
				</div>
				{#if overridePreview}
					<div class="space-y-2">
						<p
							class="text-xs font-bold tracking-[0.14em] text-muted-foreground uppercase"
						>
							Preview · first date
						</p>
						<DiscordPreview
							channel={CHANNEL[overridePreview.training.kind]}
							rendered={overridePreview.rendered}
							threadName={overridePreview.threadName}
						/>
					</div>
				{/if}
			</div>
			<Dialog.Footer>
				<Button variant="ghost" onclick={() => (overrideDraft = null)}
					>Cancel</Button
				>
				<Button onclick={saveOverride}>Save override</Button>
			</Dialog.Footer>
		{/if}
	</Dialog.Content>
</Dialog.Root>

<!-- Training editor -->
<Dialog.Root bind:open={editorOpen}>
	<Dialog.Content
		class="max-h-[calc(100dvh-2rem)] overflow-y-auto sm:max-w-4xl"
	>
		<Dialog.Header>
			<Dialog.Title>{editingId ? "Edit Training" : "Add Training"}</Dialog.Title
			>
			<Dialog.Description>
				{editingId
					? "Changes apply from today onwards; delivered dates keep their frozen snapshot."
					: "A weekly Training posts every week until disabled; a one-off posts once."}
			</Dialog.Description>
		</Dialog.Header>
		<TrainingFormFields
			bind:draft
			kindLocked={editingId !== null}
			idPrefix="a"
		/>
		<Dialog.Footer>
			<Button variant="ghost" onclick={() => (editorOpen = false)}
				>Cancel</Button
			>
			<Button onclick={saveTraining}
				>{editingId ? "Save changes" : "Create Training"}</Button
			>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>

<style>
:global(.tr-calendar .tr-holiday-day) {
	background: repeating-linear-gradient(
		-45deg,
		hsl(var(--destructive) / 0.06) 0 6px,
		transparent 6px 12px
	);
}

.tr-rule {
	display: flex;
	gap: 0.6rem;
	align-items: flex-start;
	border-radius: 0.6rem;
	padding: 0.45rem 0.6rem;
	color: hsl(var(--muted-foreground));
}

.tr-rule-mark {
	display: inline-flex;
	width: 1.25rem;
	height: 1.25rem;
	flex: none;
	align-items: center;
	justify-content: center;
	border-radius: 9999px;
	border: 1px solid hsl(var(--border));
	font-size: 0.75rem;
}

.tr-rule--won {
	color: hsl(var(--foreground));
	background: hsl(var(--primary) / 0.08);
}

.tr-rule--won .tr-rule-mark {
	border-color: hsl(var(--primary));
	background: hsl(var(--primary));
	color: hsl(var(--primary-foreground));
}

.tr-rule--shadowed {
	text-decoration: line-through;
}

.tr-rule--unreached {
	opacity: 0.55;
}
</style>
