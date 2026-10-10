<!--
	ALE-395: the Cancel dialog. It says, from Phoenix's `cancelPreview`, how
	many paid people it defers (their fee becomes a Carried Fee), how many
	contacted people go back to the Waitlist and how many live Seat Holds it
	releases, and takes an optional reason kept on the workshop and each
	Intake's history. Phoenix decides: it is refused after finalisation or
	once cancelled.
-->
<script lang="ts">
import type {
	BeginnersWorkshop,
	BeginnersWorkshopConsoleCancelPreview,
} from "@dhc/api-client";
import { toast } from "svelte-sonner";
import { cancelPreviewLines } from "#lib/beginners-workshops/console.js";
import { formatCivilDate } from "#lib/beginners-workshops/presentation.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import { cancelWorkshopSchema } from "#lib/schemas/beginnersWorkshop.js";
import { cancelWorkshop } from "./console.remote";

let {
	workshop,
	preview,
	open = $bindable(false),
}: {
	workshop: BeginnersWorkshop;
	preview: BeginnersWorkshopConsoleCancelPreview;
	open?: boolean;
} = $props();

const form = $derived(cancelWorkshop.for(workshop.id));
const lines = $derived(cancelPreviewLines(preview));
const emailed = $derived(preview.deferred + preview.returned);
let formError = $state<string | null>(null);
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-md">
		<Dialog.Header>
			<Dialog.Title>Cancel {formatCivilDate(workshop.date)}?</Dialog.Title>
			<Dialog.Description>
				This can't be undone. Nobody loses their place or their money, and the
				workshop stays visible, read-only.
			</Dialog.Description>
		</Dialog.Header>

		<form
			{...form.preflight(cancelWorkshopSchema).enhance(async (instance) => {
				formError = null;
				if (!(await instance.submit())) return;
				const result = instance.result;
				if (result?.ok) {
					const { deferred, returned } = result.data;
					toast.success(
						`Cancelled: ${deferred} deferred with a Carried Fee, ${returned} back on the Waitlist`,
					);
					open = false;
				} else if (result) {
					formError = result.error;
				}
			})}
			class="grid gap-4"
			aria-label="Cancel workshop"
		>
			<input {...form.fields.id.as("hidden", workshop.id)} />

			<ul class="grid gap-1.5 text-sm" data-testid="cancel-preview">
				{#each lines as line (line)}
					<li>{line}</li>
				{/each}
			</ul>

			<Field.Field>
				{@const props = form.fields.reason.as("text")}
				<Field.Label for={`${workshop.id}-cancel-reason`}
					>Reason (optional, kept with each Intake)</Field.Label
				>
				<Textarea
					{...props}
					id={`${workshop.id}-cancel-reason`}
					rows={2}
					maxlength={500}
				/>
				{#each form.fields.reason.issues() as issue (issue.message)}
					<Field.Error>{issue.message}</Field.Error>
				{/each}
			</Field.Field>

			{#if formError}
				<p class="text-sm text-destructive" role="alert">{formError}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="outline" onclick={() => (open = false)}
					>Keep workshop</Button
				>
				<Button type="submit" variant="destructive" disabled={!!form.pending}
					>{emailed ? `Cancel and email ${emailed}` : "Cancel workshop"}</Button
				>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
