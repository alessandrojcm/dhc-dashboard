<!--
	A Re-offer from the People roster: one person's "Offer place again"
	button and its dialog, shown only when Phoenix lists `re_offer` in the
	row's `availableCommands`. The optional note goes into the new place's
	history; Phoenix decides again under its locks and answers a stale button
	with its named reason, shown in the dialog.
-->
<script lang="ts">
import { RotateCcw } from "@lucide/svelte";
import { toast } from "svelte-sonner";
import {
	intakeCommandDone,
	intakeCommandLabel,
} from "#lib/beginners-workshops/console.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import WorkshopDialog from "#lib/components/beginners-workshops/workshop-dialog.svelte";
import { reOfferSchema } from "#lib/schemas/beginnersWorkshop.js";
import { reOffer } from "./console.remote";

let {
	workshopId,
	intakeId,
	name,
}: { workshopId: string; intakeId: string; name: string } = $props();

let open = $state(false);
let formError = $state<string | null>(null);
const form = $derived(reOffer.for(intakeId));
</script>

<!-- Badge-height (28px), so a row with the action is the same height as one
     without, and it reads as part of the row rather than a separate control. -->
<Button
	type="button"
	variant="outline"
	class="h-7 gap-1.5 rounded-md px-2.5 text-xs shadow-none has-[>svg]:px-2.5"
	aria-label={`Offer ${name} their place again`}
	onclick={() => {
		formError = null;
		open = true;
	}}
>
	<RotateCcw class="size-3.5" aria-hidden="true" />{intakeCommandLabel(
		"re_offer",
	)}
</Button>

<Dialog.Root bind:open>
	<WorkshopDialog>
		<Dialog.Header>
			<Dialog.Title>Offer {name} their place again?</Dialog.Title>
			<Dialog.Description>
				They missed the payment deadline. They will be emailed a new link to pay
				while a place is still free. Once the payment deadline has passed, they
				can pay until the workshop starts.
			</Dialog.Description>
		</Dialog.Header>

		<form
			{...form.preflight(reOfferSchema).enhance(async (instance) => {
				formError = null;
				if (!(await instance.submit())) return;
				const result = instance.result;
				if (result?.ok) {
					toast.success(intakeCommandDone("re_offer", result.data.outcome));
					open = false;
				} else if (result) {
					formError = result.error;
				}
			})}
			class="grid gap-4"
			aria-label={`Offer ${name} their place again`}
		>
			<input {...form.fields.id.as("hidden", workshopId)} />
			<input {...form.fields.intakeId.as("hidden", intakeId)} />
			<Field.Field>
				{@const props = form.fields.note.as("text")}
				<Field.Label for={`${intakeId}-re-offer-note`}
					>Note <span class="font-normal text-muted-foreground">Optional</span
					></Field.Label
				>
				<Textarea
					{...props}
					id={`${intakeId}-re-offer-note`}
					rows={2}
					maxlength={500}
					placeholder="e.g. “Rang on 12 Nov, still wants to come”"
				/>
				{#each form.fields.note.issues() as issue (issue.message)}
					<Field.Error>{issue.message}</Field.Error>
				{/each}
			</Field.Field>

			{#if formError}
				<p class="text-sm text-destructive" role="alert">{formError}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="outline" onclick={() => (open = false)}
					>Not now</Button
				>
				<Button type="submit" disabled={!!form.pending}
					>{form.pending ? "Sending…" : "Offer place and email them"}</Button
				>
			</Dialog.Footer>
		</form>
	</WorkshopDialog>
</Dialog.Root>
