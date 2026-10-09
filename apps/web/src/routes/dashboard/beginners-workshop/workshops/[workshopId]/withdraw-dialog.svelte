<!--
	ALE-387: Withdraw from the console's Intake detail — the person leaves the
	Waitlist (`removed`, restorable for 3 months). Money is never handled
	implicitly: for a paid Intake the coordinator must choose to refund the
	full fee or forfeit it (Phoenix answers `refund_choice_required`
	otherwise), and the refund-timing hint shows when the workshop is close.
	A contacted Intake just closes as declined, with no email.
-->
<script lang="ts">
import type { BeginnersWorkshopRosterIntake } from "@dhc/api-client";
import { toast } from "svelte-sonner";
import {
	formatRefundAmount,
	intakeCommandDone,
	personName,
	refundTimingHint,
} from "#lib/beginners-workshops/console.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import * as RadioGroup from "#lib/components/ui/radio-group/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import { withdrawIntakeSchema } from "#lib/schemas/beginnersWorkshop.js";
import { withdrawIntake } from "./console.remote";

let {
	workshopId,
	workshopDate,
	feeCents,
	intake,
	open = $bindable(false),
	now = () => new Date(),
}: {
	workshopId: string;
	workshopDate: string;
	feeCents: number;
	intake: BeginnersWorkshopRosterIntake;
	open?: boolean;
	/** Injectable for tests; the hint reads Dublin today from it. */
	now?: () => Date;
} = $props();

const form = $derived(withdrawIntake.for(intake.id));
const paid = $derived(intake.state === "paid");
const hint = $derived(paid ? refundTimingHint(workshopDate, now()) : null);
let refund = $state<"refund" | "forfeit" | undefined>(undefined);
let formError = $state<string | null>(null);
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-md">
		<Dialog.Header>
			<Dialog.Title
				>Withdraw {personName(intake)} from the Waitlist</Dialog.Title
			>
			<Dialog.Description>
				They leave the Waitlist entirely (restorable for 3 months). A fee is
				never carried over.
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

			{#if paid}
				<Field.Field>
					<Field.Label>What happens to their fee?</Field.Label>
					{#if hint}
						<p
							class="rounded-lg border border-amber-500 bg-amber-50 p-2.5 text-sm text-amber-900"
							data-testid="refund-timing-hint"
						>
							{hint}
						</p>
					{/if}
					<RadioGroup.Root
						value={refund}
						onValueChange={(value) => {
							if (value === "refund" || value === "forfeit") refund = value;
						}}
						class="gap-2"
						aria-label="Refund or forfeit"
					>
						<label
							class="flex items-start gap-2 rounded-lg border p-3 text-sm has-[[data-state=checked]]:border-primary"
						>
							<RadioGroup.Item value="refund" class="mt-0.5" />
							<span>
								<strong>Refund {formatRefundAmount(feeCents, "eur")}</strong>
								<span class="block text-muted-foreground"
									>The full amount, against their original payment. Email:
									“Withdrawn – refunded”.</span
								>
							</span>
						</label>
						<label
							class="flex items-start gap-2 rounded-lg border p-3 text-sm has-[[data-state=checked]]:border-primary"
						>
							<RadioGroup.Item value="forfeit" class="mt-0.5" />
							<span>
								<strong>Forfeit the fee</strong>
								<span class="block text-muted-foreground"
									>Nothing is refunded. Email: “Withdrawn – forfeited”.</span
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
					Not paid: their Intake closes as declined and their Seat Hold, if any,
					is released. No email is sent.
				</p>
			{/if}

			<Field.Field>
				{@const props = form.fields.note.as("text")}
				<Field.Label for={`${intake.id}-withdraw-note`}
					>Note (optional, recorded with the command)</Field.Label
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
					disabled={!!form.pending || (paid && !refund)}>Withdraw</Button
				>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
