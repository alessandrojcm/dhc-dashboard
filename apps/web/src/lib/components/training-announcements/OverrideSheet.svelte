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
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import * as Sheet from "$lib/components/ui/sheet";
import { Textarea } from "$lib/components/ui/textarea";
import {
	hasDraftErrors,
	newOverrideDraft,
	validateOverrideDraft,
	type OverrideDraft,
	type OverrideField,
	type OverrideFieldErrors,
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
	/** A date the caller pre-filled (e.g. an inspector's "change copy"). */
	initialDate?: string;
	onClose: () => void;
	onSaved: () => void;
} = $props();

let draft = $state<OverrideDraft>(newOverrideDraft(today, initialDate));
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
		saveError = problem?.detail ?? "Could not change the copy";
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
		data-testid="override-sheet"
	>
		<Sheet.Header>
			<Sheet.Title>Change copy for “{announcement.title}”</Sheet.Title>
			<Sheet.Description>
				Replace the title, the message, or both on these Dublin dates. A skip
				still wins over changed copy, and a bank holiday still wins over
				everything for a roll call.
			</Sheet.Description>
		</Sheet.Header>
		<div class="space-y-5 px-4 pb-2">
			{#if saveError}
				<Alert variant="destructive" data-testid="override-sheet-error">
					<AlertDescription>{saveError}</AlertDescription>
				</Alert>
			{/if}

			<div class="grid gap-3 sm:grid-cols-2">
				<div class="space-y-1.5">
					<Label for="override-from-date">First date</Label>
					<Input
						id="override-from-date"
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
					<Label for="override-to-date">Last date, inclusive</Label>
					<Input
						id="override-to-date"
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

			<div class="space-y-1.5">
				<Label for="override-title">Title (also the thread name)</Label>
				<Input
					id="override-title"
					maxlength={100}
					placeholder={announcement.title}
					value={draft.title}
					aria-invalid={fieldMessage("title") !== undefined}
					oninput={(event) => {
						draft.title = event.currentTarget.value;
					}}
				/>
				{#if fieldMessage("title")}
					<p class="text-xs font-semibold text-destructive">
						{fieldMessage("title")}
					</p>
				{/if}
			</div>

			<div class="space-y-1.5">
				<Label for="override-message">Message</Label>
				<Textarea
					id="override-message"
					rows={4}
					placeholder={announcement.message}
					value={draft.message}
					aria-invalid={fieldMessage("message") !== undefined}
					oninput={(event) => {
						draft.message = event.currentTarget.value;
					}}
				/>
				{#if fieldMessage("message")}
					<p class="text-xs font-semibold text-destructive">
						{fieldMessage("message")}
					</p>
				{/if}
				<p class="text-xs text-muted-foreground">
					Leave a field empty to keep the announcement's copy. Tokens
					{"{{date}}"}, {"{{weekday}}"} and (message only) {"{{title}}"}.
				</p>
			</div>
		</div>

		<Sheet.Footer>
			<Button variant="ghost" onclick={onClose}>Cancel</Button>
			<Button disabled={create.isPending} onclick={save}>
				{create.isPending ? "Saving…" : "Change copy"}
			</Button>
		</Sheet.Footer>
	</Sheet.Content>
</Sheet.Root>
