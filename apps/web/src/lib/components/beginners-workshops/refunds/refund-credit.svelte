<!--
	ALE-389/421: Refund credit, in either refund scope — the console's
	workshop place or the Waitlist tab's person. The button opens a
	confirmation naming the amount (when Phoenix knows it) with an optional
	note; the credit is refunded in full against its original payment and the
	person will pay for their next workshop. Mount it only where Phoenix
	offers the command (`refund_carried_fee` / `refund`).
-->
<script lang="ts">
import type { QueryClient } from "@tanstack/svelte-query";
import type { RefundScope } from "#lib/beginners-workshops/refunds/scope.js";
import { refundCreditQuestion } from "#lib/beginners-workshops/refunds/wording.js";
import WorkshopDialog from "#lib/components/beginners-workshops/workshop-dialog.svelte";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import {
	refundIntakeCreditSchema,
	refundPersonCreditSchema,
} from "#lib/schemas/beginnersWorkshop.js";
import { type NoteProps, refundSubmit, scopeQueryClient } from "./enhance.js";
import { refundIntakeCredit, refundPersonCredit } from "./refunds.remote";

let {
	scope,
	intakeId = null,
	amount = null,
	open = $bindable(false),
	queryClient,
}: {
	scope: RefundScope;
	/** The workshop place whose person's credit is refunded, in the workshop scope. */
	intakeId?: string | null;
	/** The credit's amount, worded, when Phoenix knows it. */
	amount?: string | null;
	open?: boolean;
	/** The Waitlist tab's query client; defaults to the page's. */
	queryClient?: QueryClient;
} = $props();

// The scope is fixed for the component's lifetime.
// svelte-ignore state_referenced_locally
const client = scopeQueryClient(scope, queryClient);

const workshopForm = $derived(
	scope.kind === "workshop" && intakeId
		? refundIntakeCredit.for(intakeId)
		: null,
);
const personForm = $derived(
	scope.kind === "person" ? refundPersonCredit.for(scope.waitlistId) : null,
);
const fields = $derived(workshopForm?.fields ?? personForm?.fields);
const pending = $derived(!!(workshopForm?.pending || personForm?.pending));
const noteId = $derived(
	`${scope.kind === "workshop" ? intakeId : scope.waitlistId}-refund-credit-note`,
);
let formError = $state<string | null>(null);

// A dialog reopened after Cancel starts without the last refusal message.
$effect(() => {
	if (!open) formError = null;
});

// svelte-ignore state_referenced_locally
const submit = refundSubmit(scope, "refund_credit", client, {
	done: () => (open = false),
	failed: (error) => (formError = error),
});

function enhance(instance: Parameters<typeof submit>[0]) {
	formError = null;
	return submit(instance);
}
</script>

<Button type="button" size="sm" variant="outline" onclick={() => (open = true)}
	>Refund credit</Button
>

<Dialog.Root bind:open>
	<WorkshopDialog>
		<Dialog.Header>
			<Dialog.Title>Refund credit</Dialog.Title>
			<Dialog.Description>
				{refundCreditQuestion(amount)} They will need to pay for their next workshop.
			</Dialog.Description>
		</Dialog.Header>

		{#if workshopForm}
			<form
				{...workshopForm.preflight(refundIntakeCreditSchema).enhance(enhance)}
				class="grid gap-4"
				aria-label="Refund credit"
			>
				{#if scope.kind === "workshop"}
					<input {...workshopForm.fields.id.as("hidden", scope.workshopId)} />
				{/if}
				<input {...workshopForm.fields.intakeId.as("hidden", intakeId ?? "")} />
				{@render body(workshopForm.fields.note.as("text"))}
			</form>
		{:else if personForm}
			<form
				{...personForm.preflight(refundPersonCreditSchema).enhance(enhance)}
				class="grid gap-4"
				aria-label="Refund credit"
			>
				{#if scope.kind === "person"}
					<input
						{...personForm.fields.waitlistId.as("hidden", scope.waitlistId)}
					/>
				{/if}
				{@render body(personForm.fields.note.as("text"))}
			</form>
		{/if}
	</WorkshopDialog>
</Dialog.Root>

{#snippet body(note: NoteProps)}
	<Field.Field>
		<Field.Label for={noteId}
			>Note <span class="font-normal text-muted-foreground">Optional</span
			></Field.Label
		>
		<Textarea {...note} id={noteId} rows={2} maxlength={500} />
		{#each fields?.note.issues() ?? [] as issue (issue.message)}
			<Field.Error>{issue.message}</Field.Error>
		{/each}
	</Field.Field>

	{#if formError}
		<p class="text-sm text-destructive" role="alert">{formError}</p>
	{/if}

	<Dialog.Footer>
		<Button type="button" variant="outline" onclick={() => (open = false)}
			>Keep it</Button
		>
		<Button type="submit" disabled={pending}
			>{pending ? "Refunding…" : "Refund"}</Button
		>
	</Dialog.Footer>
{/snippet}
