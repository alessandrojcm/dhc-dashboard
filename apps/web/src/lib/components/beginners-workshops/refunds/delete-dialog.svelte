<!--
	ALE-396/421: Delete from the Waitlist tab — a hard delete, at any time on
	request. The Waitlist entry, the unclaimed profile and the Guardian are
	deleted; the person's workshop places stay, anonymised, so reporting still
	adds up. When Phoenix's person read names money to settle (`refundChoice`,
	their workshop credit) the coordinator chooses refund or forfeit up front;
	a refusal on `refund` (a stale read) asks it then.
-->
<script lang="ts">
import type { BeginnersWorkshopRefundChoice } from "@dhc/api-client";
import type { QueryClient } from "@tanstack/svelte-query";
import { personScope } from "#lib/beginners-workshops/refunds/scope.js";
import { DELETE_DESCRIPTION } from "#lib/beginners-workshops/refunds/wording.js";
import WorkshopDialog from "#lib/components/beginners-workshops/workshop-dialog.svelte";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import { deletePersonSchema } from "#lib/schemas/beginnersWorkshop.js";
import { refundSubmit, scopeQueryClient } from "./enhance.js";
import RefundChoice from "./refund-choice.svelte";
import { deletePerson } from "./refunds.remote";

let {
	waitlistId,
	name,
	choice,
	open = $bindable(false),
	queryClient,
}: {
	waitlistId: string;
	name: string;
	/** Phoenix's money to settle, or `null` when none needs the choice. */
	choice: BeginnersWorkshopRefundChoice | null;
	open?: boolean;
	/** Defaults to the page's query client. */
	queryClient?: QueryClient;
} = $props();

// The person is fixed for the dialog's lifetime.
// svelte-ignore state_referenced_locally
const scope = personScope(waitlistId);
// svelte-ignore state_referenced_locally
const client = scopeQueryClient(scope, queryClient);
const form = $derived(deletePerson.for(waitlistId));

const refundIssues = $derived(form.fields.refund.issues() ?? []);

let refund = $state<"refund" | "forfeit" | undefined>(undefined);
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

const submit = refundSubmit(scope, "delete_person", client, {
	done: () => (open = false),
	failed: (error) => (formError = error),
	invalid: () => {
		if (form.fields.refund.issues()?.length) refused = true;
	},
});
</script>

<Dialog.Root bind:open>
	<WorkshopDialog>
		<Dialog.Header>
			<Dialog.Title>Delete {name}</Dialog.Title>
			<Dialog.Description>{DELETE_DESCRIPTION}</Dialog.Description>
		</Dialog.Header>

		<form
			{...form.preflight(deletePersonSchema).enhance((instance) => {
				formError = null;
				return submit(instance);
			})}
			class="grid gap-4"
			aria-label="Delete"
		>
			<input {...form.fields.waitlistId.as("hidden", waitlistId)} />
			{#if refund}
				<input {...form.fields.refund.as("hidden", refund)} />
			{/if}
			<RefundChoice
				{choice}
				command="delete_person"
				{refused}
				issues={refundIssues}
				bind:value={refund}
			/>

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
					disabled={!!form.pending || (asksChoice && !refund)}
					>{form.pending ? "Deleting…" : "Delete"}</Button
				>
			</Dialog.Footer>
		</form>
	</WorkshopDialog>
</Dialog.Root>
