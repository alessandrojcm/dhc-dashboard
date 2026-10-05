<!--
	Create one Suppression for a Training Announcement (ALE-331): one Dublin
	date or a finite inclusive range. Phoenix owns every refusal — a past
	date, a range whose delivery has begun, a one-off covered by a range —
	and its problem details render against the date field that caused them,
	never as a generic toast. Client-side checks only stop an obviously
	incomplete range from ever being sent.
-->
<script lang="ts">
import {
	trainingAnnouncementExceptionsCreateSuppressionMutation,
	trainingAnnouncementExceptionsListSuppressionsQueryKey,
	type TrainingAnnouncement,
} from "@dhc/api-client";
import { createMutation, useQueryClient } from "@tanstack/svelte-query";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";
import * as Field from "$lib/components/ui/field";
import * as Sheet from "$lib/components/ui/sheet";
import DatePicker from "$lib/components/ui/date-picker.svelte";
import { TriangleAlert } from "@lucide/svelte";
import {
	draftCalendarDate,
	draftIsoDate,
} from "$lib/training-announcements/announcement";
import {
	hasDraftErrors,
	newSuppressionDraft,
	validateSuppressionDraft,
	type SuppressionDraft,
	type SuppressionField,
	type SuppressionFieldErrors,
} from "$lib/training-announcements/exceptions";
import {
	announcementProblem,
	type AnnouncementFieldMessages,
} from "$lib/training-announcements/problem";

const queryClient = useQueryClient();

let {
	announcement,
	today,
	initialDate,
	onClose,
	onSaved,
}: {
	announcement: TrainingAnnouncement;
	/** Europe/Dublin today as `YYYY-MM-DD`, from the page load. */
	today: string;
	/** A date the caller pre-filled (e.g. an inspector's "skip this date"). */
	initialDate?: string;
	onClose: () => void;
	onSaved: () => void;
} = $props();

let draft = $state<SuppressionDraft>(
	initialDate
		? { fromDate: initialDate, toDate: initialDate }
		: newSuppressionDraft(today),
);
let saveError = $state<string | null>(null);
let fieldMessages = $state<AnnouncementFieldMessages[]>([]);
let localErrors = $state<SuppressionFieldErrors>({});

const create = createMutation(() =>
	trainingAnnouncementExceptionsCreateSuppressionMutation(),
);

function fieldMessage(field: SuppressionField): string | undefined {
	return (
		localErrors[field] ??
		fieldMessages.find((entry) => entry.field === field)?.messages[0]
	);
}

async function save() {
	saveError = null;
	fieldMessages = [];
	localErrors = validateSuppressionDraft(draft);
	if (hasDraftErrors(localErrors)) return;
	try {
		await create.mutateAsync({
			path: { id: announcement.id },
			body: { fromDate: draft.fromDate, toDate: draft.toDate },
		});
		await queryClient.invalidateQueries({
			queryKey: trainingAnnouncementExceptionsListSuppressionsQueryKey({
				path: { id: announcement.id },
			}),
		});
		onSaved();
		onClose();
	} catch (cause) {
		const problem = announcementProblem(cause);
		saveError = problem?.detail ?? "Could not skip these dates";
		fieldMessages = problem?.fieldMessages ?? [];
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
		data-testid="suppression-sheet"
	>
		<Sheet.Header>
			<Sheet.Title>Skip “{announcement.title}”</Sheet.Title>
			<Sheet.Description>
				Do not send posts on these dates. Remove the skip to resume future
				posts.
			</Sheet.Description>
		</Sheet.Header>
		<div class="space-y-5 px-4 pb-2">
			{#if saveError}
				<Alert variant="destructive" data-testid="suppression-sheet-error">
					<AlertDescription>{saveError}</AlertDescription>
				</Alert>
			{/if}

			<!-- Two single-date pickers rather than a RangeCalendar: the draft is
			     two independent fields Phoenix validates separately, and each
			     carries its own `fromDate`/`toDate` message. -->
			<div class="grid gap-3 sm:grid-cols-2">
				<Field.Field data-invalid={fieldMessage("fromDate") !== undefined}>
					<Field.Label for="suppression-from-date">First date</Field.Label>
					<DatePicker
						id="suppression-from-date"
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
					<Field.Label for="suppression-to-date"
						>Last date, inclusive</Field.Label
					>
					<DatePicker
						id="suppression-to-date"
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
			<p class="flex items-start gap-1.5 text-xs text-muted-foreground">
				<TriangleAlert aria-hidden="true" class="mt-0.5 size-3.5 flex-none" />
				For one date, set both fields to that date. A range includes the first and
				last dates.
			</p>
		</div>

		<Sheet.Footer>
			<Button variant="ghost" onclick={onClose}>Cancel</Button>
			<Button disabled={create.isPending} onclick={save}>
				{create.isPending ? "Skipping…" : "Skip these dates"}
			</Button>
		</Sheet.Footer>
	</Sheet.Content>
</Sheet.Root>
