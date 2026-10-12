<!--
	ALE-387: Withdraw from the console's Intake detail — the person leaves the
	Waitlist (`removed`, restorable for 3 months). Money is never handled
	implicitly: whenever Phoenix's row says there is money to settle
	(`refundChoice`: a paid Intake, or (ALE-389) a contacted one whose person
	holds a Carried Fee) the coordinator must choose to refund it in full —
	the amount it originally took, shown from Phoenix — or forfeit it
	(Phoenix answers `refund_choice_required` otherwise), and Phoenix's
	refund-timing hint shows when the workshop is close. Without money a
	contacted Intake just closes as declined, with no email.
-->
<script lang="ts">
import type { BeginnersWorkshopRosterIntake } from "@dhc/api-client";
import { toast } from "svelte-sonner";
import {
	intakeCommandDone,
	personName,
	refundChoiceLabel,
	refundTimingHint,
} from "#lib/beginners-workshops/console.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import WorkshopDialog from "#lib/components/beginners-workshops/workshop-dialog.svelte";
import * as Alert from "#lib/components/ui/alert/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import * as RadioGroup from "#lib/components/ui/radio-group/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import { withdrawIntakeSchema } from "#lib/schemas/beginnersWorkshop.js";
import { withdrawIntake } from "./console.remote";

let {
	workshopId,
	intake,
	open = $bindable(false),
}: {
	workshopId: string;
	intake: BeginnersWorkshopRosterIntake;
	open?: boolean;
} = $props();

const form = $derived(withdrawIntake.for(intake.id));
// Phoenix says whether the choice is required and for which money.
const choice = $derived(intake.refundChoice);
const hint = $derived(
	choice ? refundTimingHint(intake.refundTimingDaysToGo) : null,
);
let refund = $state<"refund" | "forfeit" | undefined>(undefined);
let formError = $state<string | null>(null);
</script>

<Dialog.Root bind:open>
	<WorkshopDialog>
		<Dialog.Header>
			<Dialog.Title
				>Withdraw {personName(intake)} from the Waitlist</Dialog.Title
			>
			<Dialog.Description>
				They leave the waitlist and this workshop. You can restore them to the
				waitlist for 3 months. Their payment will not be saved as workshop
				credit.
			</Dialog.Description>
		</Dialog.Header>

		<form
			{...form.preflight(withdrawIntakeSchema).enhance(async (instance) => {
				formError = null;
				if (!(await instance.submit())) return;
				const result = instance.result;
				if (result?.ok) {
					toast.success(intakeCommandDone("withdraw", result.data.outcome));
					open = false;
				} else if (result) {
					formError = result.error;
				}
			})}
			class="grid gap-4"
			aria-label="Withdraw"
		>
			<input {...form.fields.id.as("hidden", workshopId)} />
			<input {...form.fields.intakeId.as("hidden", intake.id)} />

			{#if choice}
				<Field.Field>
					<Field.Label
						>{choice.source === "carried_fee"
							? "What happens to their workshop credit?"
							: "What happens to their fee?"}</Field.Label
					>
					{#if hint}
						<Alert.Root
							class="workshop-dialog-notice block"
							data-testid="refund-timing-hint"
						>
							{hint}
						</Alert.Root>
					{/if}
					<RadioGroup.Root
						value={refund}
						onValueChange={(value) => {
							if (value === "refund" || value === "forfeit") refund = value;
						}}
						class="gap-2"
						aria-label="Refund or keep payment"
					>
						<label
							class="flex items-start gap-2 rounded-lg border p-3 text-sm has-[[data-state=checked]]:border-primary"
						>
							<RadioGroup.Item value="refund" class="mt-0.5" />
							<span>
								<strong data-testid="refund-amount"
									>{refundChoiceLabel(choice)}</strong
								>
								<span class="block text-muted-foreground"
									>Refund their original payment and email them a confirmation.</span
								>
							</span>
						</label>
						<label
							class="flex items-start gap-2 rounded-lg border p-3 text-sm has-[[data-state=checked]]:border-primary"
						>
							<RadioGroup.Item value="forfeit" class="mt-0.5" />
							<span>
								<strong>Keep the payment</strong>
								<span class="block text-muted-foreground"
									>No refund or workshop credit. They receive an email
									explaining this.</span
								>
							</span>
						</label>
					</RadioGroup.Root>
					{#if refund}
						<input {...form.fields.refund.as("hidden", refund)} />
					{/if}
					{#each form.fields.refund.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			{:else}
				<p class="text-sm">
					There is no payment to refund. Their place is closed and any checkout
					reservation is released. No email is sent.
				</p>
			{/if}

			<Field.Field>
				{@const props = form.fields.note.as("text")}
				<Field.Label for={`${intake.id}-withdraw-note`}
					>Note <span class="font-normal text-muted-foreground">Optional</span
					></Field.Label
				>
				<Textarea
					{...props}
					id={`${intake.id}-withdraw-note`}
					rows={2}
					maxlength={500}
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
					>Keep them</Button
				>
				<Button
					type="submit"
					variant="destructive"
					disabled={!!form.pending || (!!choice && !refund)}
					>{form.pending ? "Withdrawing…" : "Withdraw"}</Button
				>
			</Dialog.Footer>
		</form>
	</WorkshopDialog>
</Dialog.Root>
