<!--
	ALE-382/389/421: Record manual refund, in either refund scope — the
	coordinator paid the person back outside Stripe. Records a completed
	manual refund that follows the failed one; nothing is emailed.
-->
<script lang="ts">
import type { QueryClient } from "@tanstack/svelte-query";
import type { RefundScope } from "#lib/beginners-workshops/refunds/scope.js";
import {
	type FailedRefund,
	manualRefundDescription,
} from "#lib/beginners-workshops/refunds/wording.js";
import WorkshopDialog from "#lib/components/beginners-workshops/workshop-dialog.svelte";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import {
	recordManualRefundSchema,
	recordPersonManualRefundSchema,
} from "#lib/schemas/beginnersWorkshop.js";
import { type NoteProps, refundSubmit } from "./enhance.js";
import { recordManualRefund, recordPersonManualRefund } from "./refunds.remote";

let {
	scope,
	refund,
	name,
	open = $bindable(false),
	queryClient,
}: {
	scope: RefundScope;
	refund: FailedRefund & { id: string };
	name: string | null;
	open?: boolean;
	queryClient: QueryClient | null;
} = $props();

const workshopForm = $derived(
	scope.kind === "workshop" ? recordManualRefund.for(refund.id) : null,
);
const personForm = $derived(
	scope.kind === "person" ? recordPersonManualRefund.for(refund.id) : null,
);
const fields = $derived(workshopForm?.fields ?? personForm?.fields);
const pending = $derived(!!(workshopForm?.pending || personForm?.pending));
const noteId = $derived(`${refund.id}-manual-note`);
let formError = $state<string | null>(null);

// A dialog reopened after Cancel starts without the last refusal message.
$effect(() => {
	if (!open) formError = null;
});

// The scope and query client are fixed for the dialog's lifetime.
// svelte-ignore state_referenced_locally
const submit = refundSubmit(scope, "manual", queryClient, {
	done: () => (open = false),
	failed: (error) => (formError = error),
});

function enhance(instance: Parameters<typeof submit>[0]) {
	formError = null;
	return submit(instance);
}
</script>

<Dialog.Root bind:open>
	<WorkshopDialog>
		<Dialog.Header>
			<Dialog.Title>Record manual refund</Dialog.Title>
			<Dialog.Description
				>{manualRefundDescription(refund, name)}</Dialog.Description
			>
		</Dialog.Header>

		{#if workshopForm}
			<form
				{...workshopForm.preflight(recordManualRefundSchema).enhance(enhance)}
				class="grid gap-4"
				aria-label="Record manual refund"
			>
				{#if scope.kind === "workshop"}
					<input {...workshopForm.fields.id.as("hidden", scope.workshopId)} />
				{/if}
				<input {...workshopForm.fields.refundId.as("hidden", refund.id)} />
				{@render body(workshopForm.fields.note.as("text"))}
			</form>
		{:else if personForm}
			<form
				{...personForm
					.preflight(recordPersonManualRefundSchema)
					.enhance(enhance)}
				class="grid gap-4"
				aria-label="Record manual refund"
			>
				{#if scope.kind === "person"}
					<input
						{...personForm.fields.waitlistId.as("hidden", scope.waitlistId)}
					/>
				{/if}
				<input {...personForm.fields.refundId.as("hidden", refund.id)} />
				{@render body(personForm.fields.note.as("text"))}
			</form>
		{/if}
	</WorkshopDialog>
</Dialog.Root>

{#snippet body(note: NoteProps)}
	<Field.Field>
		<Field.Label for={noteId}>How did you pay them back? (optional)</Field.Label
		>
		<Textarea {...note} id={noteId} rows={3} maxlength={500} />
		{#each fields?.note.issues() ?? [] as issue (issue.message)}
			<Field.Error>{issue.message}</Field.Error>
		{/each}
	</Field.Field>

	{#if formError}
		<p class="text-sm text-destructive" role="alert">{formError}</p>
	{/if}

	<Dialog.Footer>
		<Button type="button" variant="outline" onclick={() => (open = false)}
			>Cancel</Button
		>
		<Button type="submit" disabled={pending}
			>{pending ? "Recording…" : "Record refund"}</Button
		>
	</Dialog.Footer>
{/snippet}
