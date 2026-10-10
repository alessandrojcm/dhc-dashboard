<!--
	ALE-382: Record manual refund — the coordinator paid the person back
	outside Stripe. Records a completed manual refund that follows the failed
	one; nothing is emailed.
-->
<script lang="ts">
import type { BeginnersWorkshopFailedRefund } from "@dhc/api-client";
import { toast } from "svelte-sonner";
import {
	formatRefundAmount,
	personName,
} from "#lib/beginners-workshops/console.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import { recordManualRefundSchema } from "#lib/schemas/beginnersWorkshop.js";
import { recordManualRefund } from "./console.remote";

let {
	workshopId,
	refund,
	open = $bindable(false),
}: {
	workshopId: string;
	refund: BeginnersWorkshopFailedRefund;
	open?: boolean;
} = $props();

const form = $derived(recordManualRefund.for(refund.id));
let formError = $state<string | null>(null);
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-md">
		<Dialog.Header>
			<Dialog.Title>Record manual refund</Dialog.Title>
			<Dialog.Description>
				Record that you paid {personName(refund)}
				{formatRefundAmount(refund.amountCents, refund.currency)} back outside Stripe.
				No email is sent.
			</Dialog.Description>
		</Dialog.Header>

		<form
			{...form.preflight(recordManualRefundSchema).enhance(async (instance) => {
				formError = null;
				if (!(await instance.submit())) return;
				const result = instance.result;
				if (result?.ok) {
					toast.success("Manual refund recorded — no email sent");
					open = false;
				} else if (result) {
					formError = result.error;
				}
			})}
			class="grid gap-4"
			aria-label="Record manual refund"
		>
			<input {...form.fields.id.as("hidden", workshopId)} />
			<input {...form.fields.refundId.as("hidden", refund.id)} />
			<Field.Field>
				{@const props = form.fields.note.as("text")}
				<Field.Label for={props.name}
					>How did you pay them back? (optional)</Field.Label
				>
				<Textarea {...props} id={props.name} rows={3} maxlength={500} />
				{#each form.fields.note.issues() as issue (issue.message)}
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
				<Button type="submit" disabled={!!form.pending}>Record refund</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
