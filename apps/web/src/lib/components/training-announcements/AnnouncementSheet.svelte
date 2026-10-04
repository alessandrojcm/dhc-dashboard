<!--
	Create or edit one Training Announcement (ALE-330).

	The API models this as two commands — `updateSchedule` and `updateCopy` —
	so the sheet reads an announcement's whole schedule and copy, and saves the
	schedule only when it actually changed: rescheduling swaps the pending job
	and can return advisory `warnings[]`, so a copy-only edit must not pay for
	it. Phoenix owns every refusal (an elapsed first send instant, a schedule
	that sets neither a weekday nor a date, copy that will not render): its
	problem details are shown against the field that caused them.

	The preview is the API's own renderer for a chosen date. Nothing here
	re-renders tokens locally, so the sheet cannot promise copy that delivery
	would refuse.
-->
<script lang="ts">
import {
	trainingAnnouncementsCreateMutation,
	trainingAnnouncementsListQueryKey,
	trainingAnnouncementsPreviewCopyMutation,
	trainingAnnouncementsUpdateCopyMutation,
	trainingAnnouncementsUpdateScheduleMutation,
	type TrainingAnnouncement,
} from "@dhc/api-client";
import { createMutation, useQueryClient } from "@tanstack/svelte-query";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import * as Sheet from "$lib/components/ui/sheet";
import { Switch } from "$lib/components/ui/switch";
import { Textarea } from "$lib/components/ui/textarea";
import { TriangleAlert } from "@lucide/svelte";
import {
	COPY_PRESETS,
	KIND_CHANNEL_LABELS,
	KIND_LABELS,
	MESSAGE_TOKENS,
	TITLE_TOKENS,
	WEEKDAY_OPTIONS,
} from "$lib/training-announcements/copy";
import {
	announcementDraft,
	draftPreviewDate,
	newAnnouncementDraft,
	scheduleChanged,
	type AnnouncementDraft,
	type AnnouncementSave,
	type AnnouncementScheduleType,
} from "$lib/training-announcements/announcement";
import {
	announcementProblem,
	type AnnouncementFieldMessages,
} from "$lib/training-announcements/problem";
import DiscordMessagePreview from "./DiscordMessagePreview.svelte";

const queryClient = useQueryClient();

let {
	announcement = null,
	today,
	onClose,
	onSaved,
}: {
	/** `null` creates a new announcement; an existing row edits it. */
	announcement?: TrainingAnnouncement | null;
	/** Europe/Dublin today as `YYYY-MM-DD`, from the page load. */
	today: string;
	onClose: () => void;
	onSaved: (saved: AnnouncementSave) => void;
} = $props();

const editing = $derived(announcement !== null);

let draft = $state<AnnouncementDraft>(
	announcement
		? announcementDraft(announcement, today)
		: newAnnouncementDraft(today),
);
let previewDate = $state(draftPreviewDate(draft, today));
let preview = $state<{ renderedMessage: string; threadName: string } | null>(
	null,
);
let saveError = $state<string | null>(null);
let previewError = $state<string | null>(null);
let fieldMessages = $state<AnnouncementFieldMessages[]>([]);

const create = createMutation(() => trainingAnnouncementsCreateMutation());
const updateSchedule = createMutation(() =>
	trainingAnnouncementsUpdateScheduleMutation(),
);
const updateCopy = createMutation(() =>
	trainingAnnouncementsUpdateCopyMutation(),
);
const previewCopy = createMutation(() =>
	trainingAnnouncementsPreviewCopyMutation(),
);

const busy = $derived(
	create.isPending || updateSchedule.isPending || updateCopy.isPending,
);

function fieldMessage(field: string): string | undefined {
	return fieldMessages.find((entry) => entry.field === field)?.messages[0];
}

function applyKindPreset(kind: AnnouncementDraft["kind"]) {
	draft.kind = kind;
	// Presets exist so the first announcement of a kind is the bot's wording,
	// verbatim. Editing copy afterwards is the committee's business.
	draft.title = COPY_PRESETS[kind].title;
	draft.message = COPY_PRESETS[kind].message;
}

function applyScheduleType(scheduleType: AnnouncementScheduleType) {
	draft.scheduleType = scheduleType;
	syncPreviewDate();
}

/**
 * The slot moved, so the preview defaults back to it. A hand-picked preview
 * date is only ever a default — choosing the slot again re-anchors it.
 */
function syncPreviewDate() {
	previewDate = draftPreviewDate(draft, today);
}

/** Exactly one of the two schedule fields is set; the other is cleared. */
function scheduleFields() {
	return draft.scheduleType === "weekly"
		? { weekday: draft.weekday, oneOffDate: null, postTime: draft.postTime }
		: { weekday: null, oneOffDate: draft.oneOffDate, postTime: draft.postTime };
}

function reportProblem(cause: unknown, fallback: string) {
	const problem = announcementProblem(cause);
	saveError = problem?.detail ?? fallback;
	fieldMessages = problem?.fieldMessages ?? [];
}

function finished(saved: AnnouncementSave) {
	void queryClient.invalidateQueries({
		queryKey: trainingAnnouncementsListQueryKey(),
	});
	onSaved(saved);
	onClose();
}

async function save() {
	saveError = null;
	fieldMessages = [];
	try {
		if (!announcement) {
			const response = await create.mutateAsync({
				body: { ...scheduleFields(), ...copyFields(), kind: draft.kind },
			});
			finished(response.data);
			return;
		}

		// Schedule first: an elapsed slot is refused before any copy is
		// written, so the sheet never half-applies a rejected edit. A copy-only
		// edit has no schedule response, so it carries no warnings.
		let warnings: AnnouncementSave["warnings"] = [];
		if (scheduleChanged(draft, announcement)) {
			const scheduled = await updateSchedule.mutateAsync({
				path: { id: announcement.id },
				body: scheduleFields(),
			});
			warnings = scheduled.data.warnings;
		}
		const copied = await updateCopy.mutateAsync({
			path: { id: announcement.id },
			body: copyFields(),
		});
		finished({ announcement: copied.data, warnings });
	} catch (cause) {
		reportProblem(cause, "Could not save the announcement");
	}
}

function copyFields() {
	return {
		title: draft.title,
		message: draft.message,
		mentionEveryone: draft.mentionEveryone,
	};
}

async function showPreview() {
	previewError = null;
	try {
		const response = await previewCopy.mutateAsync({
			body: { ...copyFields(), kind: draft.kind, date: previewDate },
		});
		preview = response.data;
	} catch (cause) {
		preview = null;
		previewError =
			announcementProblem(cause)?.detail ??
			"Could not render a preview for this copy";
	}
}
</script>

{#snippet fieldError(field: string, errorId?: string)}
	{@const message = fieldMessage(field)}
	{#if message}
		{#if errorId}
			<p
				id={errorId}
				class="flex items-start gap-1.5 text-xs font-semibold text-destructive"
			>
				<TriangleAlert aria-hidden="true" class="mt-0.5 size-3.5 flex-none" />
				{message}
			</p>
		{:else}
			<p class="text-xs font-semibold text-destructive">{message}</p>
		{/if}
	{/if}
{/snippet}
<Sheet.Root
	open
	onOpenChange={(open) => {
		if (!open) onClose();
	}}
>
	<Sheet.Content
		side="right"
		class="w-full overflow-y-auto sm:max-w-2xl"
		data-testid="announcement-sheet"
	>
		<Sheet.Header>
			<Sheet.Title>
				{editing ? "Edit announcement" : "New announcement"}
			</Sheet.Title>
			<Sheet.Description>
				{#if editing}
					Schedule changes apply to every future occurrence. Posts already
					delivered keep the copy they were sent with.
				{:else}
					A weekly announcement posts on its weekday until you pause it; a
					one-off posts once.
				{/if}
			</Sheet.Description>
		</Sheet.Header>
		<div class="space-y-6 px-4 pb-2">
			{#if saveError}
				<Alert variant="destructive" data-testid="announcement-sheet-error">
					<AlertDescription>{saveError}</AlertDescription>
				</Alert>
			{/if}

			<div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,20rem)]">
				<div class="space-y-5">
					<fieldset class="space-y-2">
						<legend class="text-sm font-semibold">Kind</legend>
						<div class="grid grid-cols-2 gap-2">
							{#each ["roll_call", "sparring"] as const as kind (kind)}
								<label
									class="flex cursor-pointer items-center justify-between gap-2 rounded-xl border px-3 py-2.5 text-sm font-semibold has-[:checked]:border-primary has-[:checked]:bg-primary/8 has-[:disabled]:cursor-not-allowed has-[:disabled]:opacity-60"
								>
									<span>
										{KIND_LABELS[kind]}
										<span
											class="block text-xs font-medium text-muted-foreground"
											>{KIND_CHANNEL_LABELS[kind]}</span
										>
									</span>
									<input
										type="radio"
										name="announcement-kind"
										value={kind}
										checked={draft.kind === kind}
										disabled={editing}
										onchange={() => applyKindPreset(kind)}
										class="accent-primary"
									/>
								</label>
							{/each}
						</div>
						{#if editing}
							<p class="text-xs text-muted-foreground">
								The kind decides the channel, so it cannot change after
								creation.
							</p>
						{/if}
					</fieldset>

					<fieldset class="space-y-2">
						<legend class="text-sm font-semibold">Repeats</legend>
						<div class="grid grid-cols-2 gap-2">
							{#each ["weekly", "one_off"] as const as option (option)}
								<label
									class="flex cursor-pointer items-center justify-between gap-2 rounded-xl border px-3 py-2.5 text-sm font-semibold has-[:checked]:border-primary has-[:checked]:bg-primary/8"
								>
									{option === "weekly" ? "Weekly" : "One-off"}
									<input
										type="radio"
										name="announcement-schedule"
										value={option}
										checked={draft.scheduleType === option}
										onchange={() => applyScheduleType(option)}
										class="accent-primary"
									/>
								</label>
							{/each}
						</div>
					</fieldset>

					<div class="grid gap-3 sm:grid-cols-2">
						{#if draft.scheduleType === "weekly"}
							<div class="space-y-1.5">
								<Label for="announcement-weekday">Weekday</Label>
								<select
									id="announcement-weekday"
									class="focus-visible:border-ring focus-visible:ring-ring/50 h-9 w-full cursor-pointer rounded-md border border-input bg-background px-3 text-sm shadow-xs outline-none focus-visible:ring-[3px]"
									value={draft.weekday}
									onchange={(event) => {
										draft.weekday = Number(event.currentTarget.value);
										syncPreviewDate();
									}}
								>
									{#each WEEKDAY_OPTIONS as option (option.value)}
										<option value={option.value}>{option.name}</option>
									{/each}
								</select>
							</div>
						{:else}
							<div class="space-y-1.5">
								<Label for="announcement-date">Date</Label>
								<Input
									id="announcement-date"
									type="date"
									min={today}
									value={draft.oneOffDate}
									aria-invalid={fieldMessage("oneOffDate") !== undefined}
									aria-describedby="announcement-date-error"
									oninput={(event) => {
										draft.oneOffDate = event.currentTarget.value;
										syncPreviewDate();
									}}
								/>
								{@render fieldError("oneOffDate", "announcement-date-error")}
							</div>
						{/if}
						<div class="space-y-1.5">
							<Label for="announcement-post-time">Post time</Label>
							<Input
								id="announcement-post-time"
								type="time"
								value={draft.postTime}
								aria-invalid={fieldMessage("postTime") !== undefined}
								aria-describedby="announcement-post-time-error"
								oninput={(event) => {
									draft.postTime = event.currentTarget.value;
								}}
							/>
							{@render fieldError("postTime", "announcement-post-time-error")}
						</div>
					</div>
					<p class="text-xs text-muted-foreground">
						Times are Europe/Dublin and follow daylight saving. The post goes
						out at the post time; there is no separate reminder.
					</p>

					<div class="space-y-1.5">
						<Label for="announcement-title">
							Title <span class="font-normal text-muted-foreground"
								>(also the thread name)</span
							>
						</Label>
						<Input
							id="announcement-title"
							maxlength={100}
							value={draft.title}
							aria-invalid={fieldMessage("title") !== undefined}
							oninput={(event) => {
								draft.title = event.currentTarget.value;
							}}
						/>
						{@render fieldError("title")}
						<p class="text-xs text-muted-foreground">
							Tokens: {TITLE_TOKENS.map((token) => `"${token}"`).join(", ")}
						</p>
					</div>

					<div class="space-y-1.5">
						<div class="flex items-center justify-between gap-3">
							<Label for="announcement-message">Message</Label>
							<button
								type="button"
								class="cursor-pointer text-xs font-semibold text-primary hover:underline"
								onclick={() => applyKindPreset(draft.kind)}
							>
								Reset to {KIND_LABELS[draft.kind].toLowerCase()} preset
							</button>
						</div>
						<Textarea
							id="announcement-message"
							rows={5}
							value={draft.message}
							aria-invalid={fieldMessage("message") !== undefined}
							oninput={(event) => {
								draft.message = event.currentTarget.value;
							}}
						/>
						{@render fieldError("message")}
						<p class="text-xs text-muted-foreground">
							Tokens: {MESSAGE_TOKENS.map((token) => `"${token}"`).join(", ")}.
							Everything else posts literally.
						</p>
					</div>

					<label
						class="flex cursor-pointer items-center justify-between gap-3 rounded-xl border px-3 py-2.5"
					>
						<span class="text-sm">
							<span class="block font-semibold">Ping @everyone</span>
							<span class="text-xs text-muted-foreground"
								>Adds the mention line and allows the ping. Off means nobody is
								notified.</span
							>
						</span>
						<Switch
							checked={draft.mentionEveryone}
							aria-label="Ping @everyone"
							onCheckedChange={(checked) => {
								draft.mentionEveryone = checked;
							}}
						/>
					</label>
				</div>

				<div class="space-y-2">
					<div class="space-y-1.5">
						<Label for="announcement-preview-date">Preview date</Label>
						<div class="flex gap-2">
							<Input
								id="announcement-preview-date"
								type="date"
								value={previewDate}
								oninput={(event) => {
									previewDate = event.currentTarget.value;
								}}
							/>
							<Button
								variant="outline"
								disabled={previewCopy.isPending}
								onclick={showPreview}
							>
								Preview copy
							</Button>
						</div>
					</div>
					{#if preview}
						<DiscordMessagePreview
							channelLabel={KIND_CHANNEL_LABELS[draft.kind]}
							renderedMessage={preview.renderedMessage}
							threadName={preview.threadName}
						/>
					{:else if previewError}
						<p
							class="text-sm font-semibold text-destructive"
							data-testid="preview-error"
						>
							{previewError}
						</p>
					{:else}
						<p class="text-xs text-muted-foreground">
							Preview renders this copy for the chosen date with the same
							function delivery uses. Nothing is posted.
						</p>
					{/if}
				</div>
			</div>
		</div>

		<Sheet.Footer>
			<Button variant="ghost" onclick={onClose}>Cancel</Button>
			<Button disabled={busy} onclick={save}>
				{busy ? "Saving…" : editing ? "Save changes" : "Create announcement"}
			</Button>
		</Sheet.Footer>
	</Sheet.Content>
</Sheet.Root>
