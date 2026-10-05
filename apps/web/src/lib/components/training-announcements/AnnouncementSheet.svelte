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
import * as Field from "$lib/components/ui/field";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import * as RadioGroup from "$lib/components/ui/radio-group";
import * as Select from "$lib/components/ui/select";
import * as Sheet from "$lib/components/ui/sheet";
import { Switch } from "$lib/components/ui/switch";
import TemplateInput from "$lib/components/ui/template-input.svelte";
import DatePicker from "$lib/components/ui/date-picker.svelte";
import { TriangleAlert } from "@lucide/svelte";
import {
	COPY_PRESETS,
	KIND_CHANNEL_LABELS,
	KIND_LABELS,
	MESSAGE_TOKENS,
	PLACEHOLDER_LABELS,
	TITLE_TOKENS,
	WEEKDAY_OPTIONS,
} from "$lib/training-announcements/copy";
import {
	announcementDraft,
	draftCalendarDate,
	draftIsoDate,
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
			announcementProblem(cause)?.detail ?? "Could not preview the message";
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
					Changes apply to future posts. Published posts stay unchanged.
				{:else}
					Choose when to post and write the message.
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
					<!-- Kind and Repeats are RadioGroups, not native radios: the
					     choice drives a side effect (the kind preset, the preview
					     anchor), so the option is the whole clickable card and the
					     dot is a visual. `disabled` on Kind while editing is what
					     stops an existing announcement changing channel. -->
					<Field.Set>
						<Field.Legend class="text-sm font-semibold">Post type</Field.Legend>
						<RadioGroup.Root
							value={draft.kind}
							onValueChange={(value) => {
								if (value) applyKindPreset(value as AnnouncementDraft["kind"]);
							}}
							disabled={editing}
							aria-label="Post type"
							class="grid grid-cols-2 gap-2"
						>
							{#each ["roll_call", "sparring"] as const as kind (kind)}
								<!-- The card is the label and the RadioGroup.Item is its
								     control, so clicking anywhere on the card picks the kind
								     while the button keeps the roving focus and arrow keys.
								     `has-[[data-state=checked]]` is what tints the selected
								     card: the item sets that state, the label only reads it. -->
								<label
									class="flex min-h-11 cursor-pointer items-start justify-between gap-2 rounded-xl border px-3 py-2.5 text-sm font-semibold has-[[data-state=checked]]:border-primary has-[[data-state=checked]]:bg-primary/8 has-[[data-disabled]]:cursor-not-allowed has-[[data-disabled]]:opacity-60"
								>
									<span class="flex min-w-0 flex-col">
										{KIND_LABELS[kind]}
										<span class="text-xs font-medium text-muted-foreground"
											>{KIND_CHANNEL_LABELS[kind]}</span
										>
									</span>
									<RadioGroup.Item
										value={kind}
										class="mt-0.5"
										aria-label={KIND_LABELS[kind]}
									/>
								</label>
							{/each}
						</RadioGroup.Root>
						{#if editing}
							<Field.Description>
								The post type and Discord channel cannot be changed.
							</Field.Description>
						{/if}
					</Field.Set>

					<Field.Set>
						<Field.Legend class="text-sm font-semibold">Repeats</Field.Legend>
						<RadioGroup.Root
							value={draft.scheduleType}
							onValueChange={(value) => {
								if (value) applyScheduleType(value as AnnouncementScheduleType);
							}}
							aria-label="Repeats"
							class="grid grid-cols-2 gap-2"
						>
							{#each ["weekly", "one_off"] as const as option (option)}
								<label
									class="flex min-h-11 cursor-pointer items-center justify-between gap-2 rounded-xl border px-3 py-2.5 text-sm font-semibold has-[[data-state=checked]]:border-primary has-[[data-state=checked]]:bg-primary/8"
								>
									{option === "weekly" ? "Weekly" : "One-off"}
									<RadioGroup.Item
										value={option}
										aria-label={option === "weekly" ? "Weekly" : "One-off"}
									/>
								</label>
							{/each}
						</RadioGroup.Root>
					</Field.Set>

					<div class="grid gap-3 sm:grid-cols-2">
						{#if draft.scheduleType === "weekly"}
							<Field.Field>
								<Field.Label for="announcement-weekday">Weekday</Field.Label>
								<Select.Root
									type="single"
									value={String(draft.weekday)}
									onValueChange={(value) => {
										draft.weekday = Number(value);
										syncPreviewDate();
									}}
								>
									<Select.Trigger
										id="announcement-weekday"
										class="w-full"
										aria-label="Weekday"
									>
										{WEEKDAY_OPTIONS.find(
											(option) => option.value === draft.weekday,
										)?.name ?? "Pick a weekday"}
									</Select.Trigger>
									<Select.Content>
										{#each WEEKDAY_OPTIONS as option (option.value)}
											<Select.Item
												value={String(option.value)}
												label={option.name}
											/>
										{/each}
									</Select.Content>
								</Select.Root>
							</Field.Field>
						{:else}
							<Field.Field
								data-invalid={fieldMessage("oneOffDate") !== undefined}
							>
								<Field.Label for="announcement-date">Date</Field.Label>
								<DatePicker
									id="announcement-date"
									dateStyle="medium"
									value={draftCalendarDate(draft.oneOffDate)}
									minValue={draftCalendarDate(today)}
									ariaInvalid={fieldMessage("oneOffDate") !== undefined}
									ariaDescribedby="announcement-date-error"
									onValueChange={(value) => {
										draft.oneOffDate = draftIsoDate(value);
										syncPreviewDate();
									}}
								/>
								{@render fieldError("oneOffDate", "announcement-date-error")}
							</Field.Field>
						{/if}
						<Field.Field data-invalid={fieldMessage("postTime") !== undefined}>
							<Field.Label for="announcement-post-time">Post time</Field.Label>
							<Input
								id="announcement-post-time"
								class="h-11 min-w-0"
								type="time"
								value={draft.postTime}
								aria-invalid={fieldMessage("postTime") !== undefined}
								aria-describedby="announcement-post-time-error"
								oninput={(event) => {
									draft.postTime = event.currentTarget.value;
								}}
							/>
							{@render fieldError("postTime", "announcement-post-time-error")}
						</Field.Field>
					</div>

					<div class="space-y-1.5">
						<Label for="announcement-title">
							Title <span class="font-normal text-muted-foreground"
								>(also the thread name)</span
							>
						</Label>
						<TemplateInput
							id="announcement-title"
							label="Title"
							maxLength={100}
							bind:value={draft.title}
							invalid={fieldMessage("title") !== undefined}
							tokens={TITLE_TOKENS.map((value) => ({
								value,
								label: PLACEHOLDER_LABELS[value],
							}))}
						/>
						{@render fieldError("title")}
					</div>

					<div class="space-y-1.5">
						<div class="flex items-center justify-between gap-3">
							<Label for="announcement-message">Message</Label>
							<button
								type="button"
								class="cursor-pointer text-xs font-semibold text-primary hover:underline"
								onclick={() => applyKindPreset(draft.kind)}
							>
								Use default message
							</button>
						</div>
						<TemplateInput
							id="announcement-message"
							label="Message"
							multiline
							bind:value={draft.message}
							invalid={fieldMessage("message") !== undefined}
							tokens={MESSAGE_TOKENS.map((value) => ({
								value,
								label: PLACEHOLDER_LABELS[value],
							}))}
						/>
						{@render fieldError("message")}
						<p class="text-xs text-muted-foreground">
							Placeholders fill in automatically when the post is sent.
						</p>
					</div>

					<label
						class="flex cursor-pointer items-center justify-between gap-3 rounded-xl border px-3 py-2.5"
					>
						<span class="text-sm">
							<span class="block font-semibold">Notify @everyone</span>
							<span class="text-xs text-muted-foreground"
								>Mention @everyone in the Discord post.</span
							>
						</span>
						<Switch
							checked={draft.mentionEveryone}
							aria-label="Notify @everyone"
							onCheckedChange={(checked) => {
								draft.mentionEveryone = checked;
							}}
						/>
					</label>
				</div>

				<div class="space-y-2">
					<Field.Field>
						<Field.Label for="announcement-preview-date"
							>Preview date</Field.Label
						>
						<div class="flex gap-2">
							<DatePicker
								id="announcement-preview-date"
								value={draftCalendarDate(previewDate)}
								onValueChange={(value) => {
									previewDate = draftIsoDate(value);
								}}
							/>
							<Button
								variant="outline"
								disabled={previewCopy.isPending}
								onclick={showPreview}
							>
								Preview
							</Button>
						</div>
					</Field.Field>
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
							Preview the message for this date without posting it.
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
