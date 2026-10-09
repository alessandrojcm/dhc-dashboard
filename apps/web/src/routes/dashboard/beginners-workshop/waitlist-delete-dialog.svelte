<!--
	ALE-396: Delete from the Waitlist tab — a hard delete, at any time on
	request (spec story 120). The Waitlist entry, the unclaimed profile and the
	Guardian are deleted; the person's Intakes stay, anonymised, so reporting
	still adds up. When the person holds a Carried Fee (`carriedFee` from the
	page's Carried Fee column, or Phoenix's `refund_choice_required`), the
	coordinator chooses refund or forfeit first.
-->
<script lang="ts">
import type {
	BeginnersCarriedFeeStatus,
	BeginnersWorkshopDeletePersonRequest,
	WaitlistEntry,
} from "@dhc/api-client";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import * as RadioGroup from "#lib/components/ui/radio-group/index.js";
import type { WithdrawOutcome } from "./waitlist-table.svelte.js";

let {
	entry,
	carriedFee = null,
	open = $bindable(false),
	pending = false,
	onDelete,
}: {
	entry: WaitlistEntry;
	carriedFee?: BeginnersCarriedFeeStatus | null;
	open?: boolean;
	pending?: boolean;
	onDelete: (
		body: BeginnersWorkshopDeletePersonRequest,
	) => Promise<WithdrawOutcome>;
} = $props();

let refund = $state<"refund" | "forfeit" | undefined>(undefined);
// The page already knows about a live fee; Phoenix answers for one it didn't.
let phoenixAsked = $state(false);
const askRefund = $derived(carriedFee !== null || phoenixAsked);
let error = $state<string | null>(null);

async function submit(event: SubmitEvent) {
	event.preventDefault();
	error = null;
	const body: BeginnersWorkshopDeletePersonRequest = {};
	if (refund) body.refund = refund === "refund";
	const outcome = await onDelete(body);
	if (outcome.ok) {
		open = false;
		return;
	}
	if (outcome.code === "refund_choice_required") phoenixAsked = true;
	error = outcome.error;
}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-md">
		<Dialog.Header>
			<Dialog.Title>Delete {entry.fullName}</Dialog.Title>
			<Dialog.Description>
				Their Waitlist entry, details and Guardian are deleted for good and
				can't be restored. Their Intakes stay in the reports, anonymised. Nobody
				is emailed.
			</Dialog.Description>
		</Dialog.Header>

		<form class="grid gap-4" aria-label="Delete" onsubmit={submit}>
			{#if askRefund}
				<Field.Field>
					<Field.Label>They hold a Carried Fee. What happens to it?</Field.Label
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
									>Against their original payment.</span
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
									>Nothing is refunded.</span
								>
							</span>
						</label>
					</RadioGroup.Root>
				</Field.Field>
			{/if}

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
					disabled={pending || (askRefund && !refund)}>Delete</Button
				>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
