<!--
	Create one Override for a Training Announcement (ALE-331): one Dublin
	date or a finite inclusive range replacing the title, the message, or
	both. Overlapping ranges are rejected by the GiST exclusion, and that
	rejection — like a past date or a begun delivery — renders against the
	form, never as a generic toast. The kind and the `@everyone` setting
	cannot be overridden; they stay with the announcement.
-->
<script lang="ts">
import {
	trainingAnnouncementExceptionsCreateOverrideMutation,
	trainingAnnouncementExceptionsListOverridesQueryKey,
	type TrainingAnnouncement,
} from "@dhc/api-client";
import { createMutation, useQueryClient } from "@tanstack/svelte-query";
import { Alert, AlertDescription } from "#lib/components/ui/alert/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import * as Sheet from "#lib/components/ui/sheet/index.js";
import TemplateInput from "#lib/components/ui/template-input.svelte";
import {
	MESSAGE_TOKENS,
	PLACEHOLDER_LABELS,
	TITLE_TOKENS,
} from "#lib/training-announcements/copy.js";
import DatePicker from "#lib/components/ui/date-picker.svelte";
import {
	draftCalendarDate,
	draftIsoDate,
} from "#lib/training-announcements/announcement.js";
import {
	hasDraftErrors,
	newOverrideDraft,
	validateOverrideDraft,
	friendlyOverrideDetail,
	friendlyOverrideFieldMessage,
	type OverrideDraft,
	type OverrideField,
	type OverrideFieldErrors,
} from "#lib/training-announcements/exceptions.js";
import {
	announcementProblem,
	type AnnouncementFieldMessages,
} from "#lib/training-announcements/problem.js";

const queryClient = useQueryClient();

let {
	announcement,
	today,
	initialDate,
	initialTitle,
	initialMessage,
	onClose,
	onSaved,
}: {
	announcement: TrainingAnnouncement;
	/** Europe/Dublin today as `YYYY-MM-DD`, from the page load. */
	today: string;
	/** A date the caller pre-filled (e.g. an inspector's "change copy"). */
	initialDate?: string;
	/** The copy the caller pre-filled: the occurrence's resolved templates
	 * from the inspector, or the announcement's own copy from the detail
	 * column. Empty stays empty so it keeps the existing text. */
	initialTitle?: string | null;
	initialMessage?: string | null;
	onClose: () => void;
	onSaved: () => void;
} = $props();

let draft = $state<OverrideDraft>(
	newOverrideDraft(today, initialDate, {
		title: initialTitle ?? undefined,
		message: initialMessage ?? undefined,
	}),
);
let saveError = $state<string | null>(null);
let fieldMessages = $state<AnnouncementFieldMessages[]>([]);
let localErrors = $state<OverrideFieldErrors>({});

const create = createMutation(() =>
	trainingAnnouncementExceptionsCreateOverrideMutation(),
);

function fieldMessage(field: OverrideField): string | undefined {
	return (
		localErrors[field] ??
		fieldMessages.find((entry) => entry.field === field)?.messages[0]
	);
}

async function save() {
	saveError = null;
	fieldMessages = [];
	localErrors = validateOverrideDraft(draft);
	if (hasDraftErrors(localErrors)) return;
	try {
		await create.mutateAsync({
			path: { id: announcement.id },
			body: {
				fromDate: draft.fromDate,
				toDate: draft.toDate,
				title: draft.title.trim() === "" ? null : draft.title,
				message: draft.message.trim() === "" ? null : draft.message,
			},
		});
		await queryClient.invalidateQueries({
			queryKey: trainingAnnouncementExceptionsListOverridesQueryKey({
				path: { id: announcement.id },
			}),
		});
		onSaved();
		onClose();
	} catch (cause) {
		const problem = announcementProblem(cause);
		// An overlap refusal names the database rule, never the way out:
		// the existing text change must be deleted first.
		saveError =
			friendlyOverrideDetail(problem?.detail) ??
			"Could not save the text changes";
		fieldMessages = (problem?.fieldMessages ?? []).map((entry) => ({
			field: entry.field,
			messages: entry.messages.map(friendlyOverrideFieldMessage),
		}));
	}
}
</script>

<Sheet.Root
	open
	onOpenChange={(open) => {
		if (!open) onClose();
	}}
>
	<Sheet.Content
		side="right"
		class="w-full overflow-y-auto sm:max-w-lg"
		data-testid="override-sheet"
	>
		<Sheet.Header>
			<Sheet.Title>Change text for “{announcement.title}”</Sheet.Title>
			<Sheet.Description>
				Change the title or message for the selected dates. Skipped posts will
				not be sent. Roll calls are not sent on bank holidays; a holiday notice
				is posted instead.
			</Sheet.Description>
		</Sheet.Header>
		<div class="space-y-5 px-4 pb-2">
			{#if saveError}
				<Alert variant="destructive" data-testid="override-sheet-error">
					<AlertDescription>{saveError}</AlertDescription>
				</Alert>
			{/if}

			<!-- Two single-date pickers rather than a RangeCalendar: the draft is
			     two independent fields Phoenix validates separately, and each
			     carries its own `fromDate`/`toDate` message. -->
			<div class="grid gap-3 sm:grid-cols-2">
				<Field.Field data-invalid={fieldMessage("fromDate") !== undefined}>
					<Field.Label for="override-from-date">First date</Field.Label>
					<DatePicker
						id="override-from-date"
						value={draftCalendarDate(draft.fromDate)}
						minValue={draftCalendarDate(today)}
						ariaInvalid={fieldMessage("fromDate") !== undefined}
						onValueChange={(value) => {
							draft.fromDate = draftIsoDate(value);
						}}
					/>
					{#if fieldMessage("fromDate")}
						<Field.Error>{fieldMessage("fromDate")}</Field.Error>
					{/if}
				</Field.Field>
				<Field.Field data-invalid={fieldMessage("toDate") !== undefined}>
					<Field.Label for="override-to-date">Last date, inclusive</Field.Label>
					<DatePicker
						id="override-to-date"
						value={draftCalendarDate(draft.toDate)}
						minValue={draftCalendarDate(draft.fromDate || today)}
						ariaInvalid={fieldMessage("toDate") !== undefined}
						onValueChange={(value) => {
							draft.toDate = draftIsoDate(value);
						}}
					/>
					{#if fieldMessage("toDate")}
						<Field.Error>{fieldMessage("toDate")}</Field.Error>
					{/if}
				</Field.Field>
			</div>

			<Field.Field data-invalid={fieldMessage("title") !== undefined}>
				<Field.Label for="override-title"
					>Title (also the thread name)</Field.Label
				>
				<TemplateInput
					id="override-title"
					label="Title"
					maxLength={100}
					bind:value={draft.title}
					invalid={fieldMessage("title") !== undefined}
					tokens={TITLE_TOKENS.map((value) => ({
						value,
						label: PLACEHOLDER_LABELS[value],
					}))}
				/>
				{#if fieldMessage("title")}
					<Field.Error>{fieldMessage("title")}</Field.Error>
				{/if}
			</Field.Field>

			<Field.Field data-invalid={fieldMessage("message") !== undefined}>
				<Field.Label for="override-message">Message</Field.Label>
				<TemplateInput
					id="override-message"
					label="Message"
					multiline
					bind:value={draft.message}
					invalid={fieldMessage("message") !== undefined}
					tokens={MESSAGE_TOKENS.map((value) => ({
						value,
						label: PLACEHOLDER_LABELS[value],
					}))}
				/>
				{#if fieldMessage("message")}
					<Field.Error>{fieldMessage("message")}</Field.Error>
				{/if}
				<Field.Description>
					Leave a field empty to keep its existing text.
				</Field.Description>
			</Field.Field>
		</div>

		<Sheet.Footer>
			<Button variant="ghost" onclick={onClose}>Cancel</Button>
			<Button disabled={create.isPending} onclick={save}>
				{create.isPending ? "Saving…" : "Change text"}
			</Button>
		</Sheet.Footer>
	</Sheet.Content>
</Sheet.Root>
