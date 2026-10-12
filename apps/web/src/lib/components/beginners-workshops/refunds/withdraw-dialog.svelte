<!--
	ALE-387/421: Withdraw, in either refund scope — the console's workshop
	place or the Waitlist tab's person. The person leaves the Waitlist
	(`removed`, restorable for 3 months). Money is never handled implicitly:
	whenever Phoenix's read says there is money to settle (`refundChoice`)
	the coordinator chooses up front to refund it in full — the amount it
	originally took — or forfeit it; when Phoenix still refuses on `refund`
	(a stale read) the choice is asked then. On a workshop place Phoenix's
	refund-timing hint shows when the workshop is close, and without money
	the place just closes, with no email.
-->
<script lang="ts">
import type { BeginnersWorkshopRefundChoice } from "@dhc/api-client";
import type { QueryClient } from "@tanstack/svelte-query";
import type { RefundScope } from "#lib/beginners-workshops/refunds/scope.js";
import {
	NO_PAYMENT_TO_REFUND,
	refundTimingHint,
	withdrawDescription,
} from "#lib/beginners-workshops/refunds/wording.js";
import WorkshopDialog from "#lib/components/beginners-workshops/workshop-dialog.svelte";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import {
	withdrawIntakeSchema,
	withdrawPersonSchema,
} from "#lib/schemas/beginnersWorkshop.js";
import { type NoteProps, refundSubmit, scopeQueryClient } from "./enhance.js";
import RefundChoice from "./refund-choice.svelte";
import { withdrawIntake, withdrawPerson } from "./refunds.remote";

let {
	scope,
	intakeId = null,
	name,
	choice,
	refundTimingDaysToGo = null,
	open = $bindable(false),
	queryClient,
}: {
	scope: RefundScope;
	/** The workshop place withdrawn from, in the workshop scope. */
	intakeId?: string | null;
	name: string;
	/** Phoenix's money to settle, or `null` when none needs the choice. */
	choice: BeginnersWorkshopRefundChoice | null;
	refundTimingDaysToGo?: number | null;
	open?: boolean;
	/** The Waitlist tab's query client; defaults to the page's. */
	queryClient?: QueryClient;
} = $props();

// The scope is fixed for the dialog's lifetime.
// svelte-ignore state_referenced_locally
const client = scopeQueryClient(scope, queryClient);

const workshopForm = $derived(
	scope.kind === "workshop" && intakeId ? withdrawIntake.for(intakeId) : null,
);
const personForm = $derived(
	scope.kind === "person" ? withdrawPerson.for(scope.waitlistId) : null,
);
const fields = $derived(workshopForm?.fields ?? personForm?.fields);
const pending = $derived(!!(workshopForm?.pending || personForm?.pending));
const refundIssues = $derived(fields?.refund.issues() ?? []);
const noteIssues = $derived(fields?.note.issues() ?? []);

const noteId = $derived(
	`${scope.kind === "workshop" ? intakeId : scope.waitlistId}-withdraw-note`,
);

let refund = $state<"refund" | "forfeit" | undefined>(undefined);
// Phoenix refused on `refund`: the read was stale, so ask now.
let refused = $state(false);
let formError = $state<string | null>(null);

// A dialog reopened after Cancel starts without the last choice or refusal message.
$effect(() => {
	if (!open) {
		refund = undefined;
		formError = null;
	}
});
const asksChoice = $derived(
	choice !== null || refused || refundIssues.length > 0,
);
const hint = $derived(
	choice && scope.kind === "workshop"
		? refundTimingHint(refundTimingDaysToGo)
		: null,
);

// svelte-ignore state_referenced_locally
const submit = refundSubmit(scope, "withdraw", client, {
	done: () => (open = false),
	failed: (error) => (formError = error),
	invalid: () => {
		if (fields?.refund.issues()?.length) refused = true;
	},
});

function enhance(instance: Parameters<typeof submit>[0]) {
	formError = null;
	return submit(instance);
}
</script>

<Dialog.Root bind:open>
	<WorkshopDialog>
		<Dialog.Header>
			<Dialog.Title>Withdraw {name} from the Waitlist</Dialog.Title>
			<Dialog.Description>{withdrawDescription(scope)}</Dialog.Description>
		</Dialog.Header>

		{#if workshopForm}
			<form
				{...workshopForm.preflight(withdrawIntakeSchema).enhance(enhance)}
				class="grid gap-4"
				aria-label="Withdraw"
			>
				{#if scope.kind === "workshop"}
					<input {...workshopForm.fields.id.as("hidden", scope.workshopId)} />
				{/if}
				<input {...workshopForm.fields.intakeId.as("hidden", intakeId ?? "")} />
				{#if refund}
					<input {...workshopForm.fields.refund.as("hidden", refund)} />
				{/if}
				{@render body(workshopForm.fields.note.as("text"))}
			</form>
		{:else if personForm}
			<form
				{...personForm.preflight(withdrawPersonSchema).enhance(enhance)}
				class="grid gap-4"
				aria-label="Withdraw"
			>
				{#if scope.kind === "person"}
					<input
						{...personForm.fields.waitlistId.as("hidden", scope.waitlistId)}
					/>
				{/if}
				{#if refund}
					<input {...personForm.fields.refund.as("hidden", refund)} />
				{/if}
				{@render body(personForm.fields.note.as("text"))}
			</form>
		{/if}
	</WorkshopDialog>
</Dialog.Root>

{#snippet body(note: NoteProps)}
	<RefundChoice
		{choice}
		command="withdraw"
		{refused}
		issues={refundIssues}
		{hint}
		bind:value={refund}
	/>
	{#if !asksChoice && scope.kind === "workshop"}
		<p class="text-sm">{NO_PAYMENT_TO_REFUND}</p>
	{/if}

	<Field.Field>
		<Field.Label for={noteId}
			>Note <span class="font-normal text-muted-foreground">Optional</span
			></Field.Label
		>
		<Textarea {...note} id={noteId} rows={2} maxlength={500} />
		{#each noteIssues as issue (issue.message)}
			<Field.Error>{issue.message}</Field.Error>
		{/each}
	</Field.Field>

	{#if formError}
		<p class="text-sm text-destructive" role="alert">{formError}</p>
	{/if}

	<Dialog.Footer>
		<Button type="button" variant="outline" onclick={() => (open = false)}
			>Keep them</Button
		>
		<Button
			type="submit"
			variant="destructive"
			disabled={pending || (asksChoice && !refund)}
			>{pending ? "Withdrawing…" : "Withdraw"}</Button
		>
	</Dialog.Footer>
{/snippet}
