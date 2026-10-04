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
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import * as Sheet from "$lib/components/ui/sheet";
import { TriangleAlert } from "@lucide/svelte";
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
				No post goes out on these Dublin dates. Removing the skip later restores
				the posts; past deliveries keep their evidence.
			</Sheet.Description>
		</Sheet.Header>
		<div class="space-y-5 px-4 pb-2">
			{#if saveError}
				<Alert variant="destructive" data-testid="suppression-sheet-error">
					<AlertDescription>{saveError}</AlertDescription>
				</Alert>
			{/if}

			<div class="grid gap-3 sm:grid-cols-2">
				<div class="space-y-1.5">
					<Label for="suppression-from-date">First date</Label>
					<Input
						id="suppression-from-date"
						type="date"
						min={today}
						value={draft.fromDate}
						aria-invalid={fieldMessage("fromDate") !== undefined}
						oninput={(event) => {
							draft.fromDate = event.currentTarget.value;
						}}
					/>
					{#if fieldMessage("fromDate")}
						<p class="text-xs font-semibold text-destructive">
							{fieldMessage("fromDate")}
						</p>
					{/if}
				</div>
				<div class="space-y-1.5">
					<Label for="suppression-to-date">Last date, inclusive</Label>
					<Input
						id="suppression-to-date"
						type="date"
						min={draft.fromDate || today}
						value={draft.toDate}
						aria-invalid={fieldMessage("toDate") !== undefined}
						oninput={(event) => {
							draft.toDate = event.currentTarget.value;
						}}
					/>
					{#if fieldMessage("toDate")}
						<p class="text-xs font-semibold text-destructive">
							{fieldMessage("toDate")}
						</p>
					{/if}
				</div>
			</div>
			<p class="flex items-start gap-1.5 text-xs text-muted-foreground">
				<TriangleAlert aria-hidden="true" class="mt-0.5 size-3.5 flex-none" />
				Use the same date twice to skip one night; a range skips every occurrence
				between them. Dates are Europe/Dublin days.
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
