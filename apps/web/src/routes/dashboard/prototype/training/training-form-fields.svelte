<!-- PROTOTYPE — throwaway. Training create/edit fields with a live rendered preview. -->
<script lang="ts">
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import { Switch } from "$lib/components/ui/switch";
import { Textarea } from "$lib/components/ui/textarea";
import { AlertTriangle } from "@lucide/svelte";
import DiscordPreview from "./discord-preview.svelte";
import {
	CHANNEL,
	KIND_LABEL,
	PRESETS,
	TODAY,
	WEEKDAYS,
	renderCopy,
	renderMessage,
	validateCopy,
	type TrainingDraft,
} from "./training-prototype-store.svelte";

let {
	draft = $bindable(),
	kindLocked = false,
	idPrefix = "training",
}: { draft: TrainingDraft; kindLocked?: boolean; idPrefix?: string } = $props();

const problems = $derived(validateCopy(draft.message));
const sampleDate = $derived(
	draft.scheduleType === "one_off" ? draft.date : nextWeekday(draft.weekday),
);
const previewTitle = $derived(
	renderCopy(draft.title, {
		title: "",
		date: sampleDate,
		startTime: draft.startTime,
		endTime: draft.endTime,
	}),
);
const preview = $derived(
	renderMessage(draft.message, draft.everyone, {
		title: previewTitle,
		date: sampleDate,
		startTime: draft.startTime,
		endTime: draft.endTime,
	}),
);

function nextWeekday(weekday: number) {
	const base = new Date(`${TODAY}T00:00:00`);
	const delta = (weekday - base.getDay() + 7) % 7;
	base.setDate(base.getDate() + delta);
	return base.toISOString().slice(0, 10);
}

function applyPreset() {
	draft.title = PRESETS[draft.kind].title;
	draft.message = PRESETS[draft.kind].message;
}
</script>

<div class="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,22rem)]">
	<div class="space-y-4">
		<fieldset class="space-y-2">
			<legend class="text-sm font-semibold">Notification kind</legend>
			<div class="grid grid-cols-2 gap-2">
				{#each ["roll_call", "sparring"] as const as kind (kind)}
					<label
						class="flex cursor-pointer items-center justify-between gap-2 rounded-xl border px-3 py-2.5 text-sm font-semibold transition-colors has-[:checked]:border-primary has-[:checked]:bg-primary/8 has-[:disabled]:cursor-not-allowed has-[:disabled]:opacity-60"
					>
						<span>
							{KIND_LABEL[kind]}
							<span class="block text-xs font-medium text-muted-foreground"
								>posts to {CHANNEL[kind]}</span
							>
						</span>
						<input
							type="radio"
							name="{idPrefix}-kind"
							value={kind}
							bind:group={draft.kind}
							disabled={kindLocked}
							onchange={applyPreset}
							class="accent-primary"
						/>
					</label>
				{/each}
			</div>
			{#if kindLocked}
				<p class="text-xs text-muted-foreground">
					Kind is fixed once a Training exists — it decides the channel.
				</p>
			{/if}
		</fieldset>

		<fieldset class="space-y-2">
			<legend class="text-sm font-semibold">Repeats</legend>
			<div class="grid grid-cols-2 gap-2">
				<label
					class="flex cursor-pointer items-center justify-between gap-2 rounded-xl border px-3 py-2.5 text-sm font-semibold has-[:checked]:border-primary has-[:checked]:bg-primary/8"
				>
					Weekly
					<input
						type="radio"
						name="{idPrefix}-repeat"
						value="weekly"
						bind:group={draft.scheduleType}
						class="accent-primary"
					/>
				</label>
				<label
					class="flex cursor-pointer items-center justify-between gap-2 rounded-xl border px-3 py-2.5 text-sm font-semibold has-[:checked]:border-primary has-[:checked]:bg-primary/8"
				>
					One-off
					<input
						type="radio"
						name="{idPrefix}-repeat"
						value="one_off"
						bind:group={draft.scheduleType}
						class="accent-primary"
					/>
				</label>
			</div>
		</fieldset>

		<div class="grid gap-3 sm:grid-cols-3">
			{#if draft.scheduleType === "weekly"}
				<div class="space-y-1.5">
					<Label for="{idPrefix}-weekday">Weekday</Label>
					<select
						id="{idPrefix}-weekday"
						bind:value={draft.weekday}
						class="flex h-9 w-full cursor-pointer rounded-md border border-input bg-background px-3 text-sm"
					>
						{#each WEEKDAYS as name, index (name)}
							<option value={index}>{name}</option>
						{/each}
					</select>
				</div>
			{:else}
				<div class="space-y-1.5">
					<Label for="{idPrefix}-date">Date</Label>
					<Input
						id="{idPrefix}-date"
						type="date"
						min={TODAY}
						bind:value={draft.date}
					/>
				</div>
			{/if}
			<div class="space-y-1.5">
				<Label for="{idPrefix}-start">Post time</Label>
				<Input id="{idPrefix}-start" type="time" bind:value={draft.startTime} />
			</div>
			<div class="space-y-1.5">
				<Label for="{idPrefix}-end">End time</Label>
				<Input id="{idPrefix}-end" type="time" bind:value={draft.endTime} />
			</div>
		</div>
		<p class="text-xs text-muted-foreground">
			Times are Europe/Dublin. The post goes out at the post time on each
			occurrence date; it cannot cross midnight.
		</p>

		<div class="space-y-1.5">
			<Label for="{idPrefix}-title"
				>Title <span class="font-normal text-muted-foreground"
					>(also the thread name)</span
				></Label
			>
			<Input id="{idPrefix}-title" bind:value={draft.title} maxlength={100} />
		</div>

		<div class="space-y-1.5">
			<div class="flex items-center justify-between">
				<Label for="{idPrefix}-message">Message</Label>
				<button
					type="button"
					class="cursor-pointer text-xs font-semibold text-primary hover:underline"
					onclick={applyPreset}
				>
					Reset to {KIND_LABEL[draft.kind].toLowerCase()} preset
				</button>
			</div>
			<Textarea id="{idPrefix}-message" rows={4} bind:value={draft.message} />
			<p class="text-xs text-muted-foreground">
				Tokens: <code class="font-mono">{"{{title}}"}</code>
				<code class="font-mono">{"{{date}}"}</code>
				<code class="font-mono">{"{{startTime}}"}</code>
				<code class="font-mono">{"{{endTime}}"}</code>. Everything else posts
				literally.
			</p>
			{#if problems.length > 0}
				<ul class="space-y-1 text-xs font-semibold text-destructive">
					{#each problems as problem (problem)}
						<li class="flex items-start gap-1.5">
							<AlertTriangle
								aria-hidden="true"
								class="mt-0.5 size-3.5 flex-none"
							/>
							{problem}
						</li>
					{/each}
				</ul>
			{/if}
		</div>

		<label
			class="flex cursor-pointer items-center justify-between gap-3 rounded-xl border px-3 py-2.5"
		>
			<span class="text-sm">
				<span class="block font-semibold">Ping @everyone</span>
				<span class="text-xs text-muted-foreground"
					>Adds the mention line and allows the ping. Off = nobody is notified.</span
				>
			</span>
			<Switch bind:checked={draft.everyone} />
		</label>
	</div>

	<div class="space-y-2">
		<p
			class="text-xs font-bold tracking-[0.14em] text-muted-foreground uppercase"
		>
			Preview · next occurrence
		</p>
		<DiscordPreview
			channel={CHANNEL[draft.kind]}
			rendered={preview}
			threadName={previewTitle}
		/>
		<p class="text-xs text-muted-foreground">
			Preview uses the same renderer as delivery. Nothing is posted.
		</p>
	</div>
</div>
