<!--
	ALE-387: Withdraw from the Waitlist tab — the person leaves the Waitlist
	(`removed`, restorable for 3 months). The Waitlist knows nothing about
	Intakes, so the dialog asks no money question up front: when the person
	has a paid Intake, Phoenix answers `refund_choice_required` and the
	dialog then asks the coordinator to refund or forfeit the fee explicitly.
-->
<script lang="ts">
import type {
	BeginnersWorkshopWithdrawRequest,
	WaitlistEntry,
} from "@dhc/api-client";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import * as RadioGroup from "#lib/components/ui/radio-group/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import type { WithdrawOutcome } from "./waitlist-table.svelte.js";

let {
	entry,
	open = $bindable(false),
	pending = false,
	onWithdraw,
}: {
	entry: WaitlistEntry;
	open?: boolean;
	pending?: boolean;
	onWithdraw: (
		body: BeginnersWorkshopWithdrawRequest,
	) => Promise<WithdrawOutcome>;
} = $props();

let note = $state("");
let refund = $state<"refund" | "forfeit" | undefined>(undefined);
let askRefund = $state(false);
let error = $state<string | null>(null);

async function submit(event: SubmitEvent) {
	event.preventDefault();
	error = null;
	const body: BeginnersWorkshopWithdrawRequest = {};
	if (refund) body.refund = refund === "refund";
	const trimmed = note.trim();
	if (trimmed) body.note = trimmed;
	const outcome = await onWithdraw(body);
	if (outcome.ok) {
		open = false;
		return;
	}
	if (outcome.code === "refund_choice_required") askRefund = true;
	error = outcome.error;
}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-md">
		<Dialog.Header>
			<Dialog.Title>Withdraw {entry.fullName} from the Waitlist</Dialog.Title>
			<Dialog.Description>
				They leave the Waitlist entirely (restorable for 3 months). An open
				Intake closes; a fee is never carried over.
			</Dialog.Description>
		</Dialog.Header>

		<form class="grid gap-4" aria-label="Withdraw" onsubmit={submit}>
			{#if askRefund}
				<Field.Field>
					<Field.Label
						>They've paid for a place. What happens to the fee?</Field.Label
					>
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
								<strong>Refund the full fee</strong>
								<span class="block text-muted-foreground"
									>Against their original payment. Email: “Withdrawn –
									refunded”.</span
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
				</Field.Field>
			{/if}

			<Field.Field>
				<Field.Label for={`${entry.id}-withdraw-note`}
					>Note (optional, kept in their Intake's history if they have one)</Field.Label
				>
				<Textarea
					id={`${entry.id}-withdraw-note`}
					bind:value={note}
					rows={2}
					maxlength={500}
				/>
			</Field.Field>

			{#if error}
				<p class="text-sm text-destructive" role="alert">{error}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="outline" onclick={() => (open = false)}
					>Keep them</Button
				>
				<Button
					type="submit"
					variant="destructive"
					disabled={pending || (askRefund && !refund)}>Withdraw</Button
				>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
