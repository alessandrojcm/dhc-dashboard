<!--
	ALE-421: the refund-or-forfeit choice, for Withdraw (both scopes) and
	Delete. It is asked up front whenever Phoenix sends `refundChoice` — the
	refund option names the full amount that money originally took — and
	also once Phoenix has refused the command on `refund` (`refused`, or an
	issue on the field): a stale read that did not know about the money, so
	the amount is unknown. Otherwise it renders nothing. The form owns the
	hidden `refund` field; this only binds the chosen value.
-->
<script lang="ts">
import type { BeginnersWorkshopRefundChoice } from "@dhc/api-client";
import {
	refundChoiceLabel,
	refundChoiceOptions,
	refundChoiceQuestion,
} from "#lib/beginners-workshops/refunds/wording.js";
import * as Alert from "#lib/components/ui/alert/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import * as RadioGroup from "#lib/components/ui/radio-group/index.js";

let {
	choice,
	command,
	refused = false,
	issues = [],
	hint = null,
	value = $bindable(),
}: {
	choice: BeginnersWorkshopRefundChoice | null;
	command: "withdraw" | "delete_person";
	/** Phoenix refused the command on `refund` (`refund_choice_required`). */
	refused?: boolean;
	/** The form's issues on `refund`. */
	issues?: readonly { message: string }[];
	/** Phoenix's refund-timing hint, worded. */
	hint?: string | null;
	value?: "refund" | "forfeit";
} = $props();

const asked = $derived(choice !== null || refused || issues.length > 0);
const options = $derived(refundChoiceOptions(command));
</script>

{#if asked}
	<Field.Field>
		<Field.Label>{refundChoiceQuestion(choice)}</Field.Label>
		{#if hint}
			<Alert.Root
				class="workshop-dialog-notice block"
				data-testid="refund-timing-hint"
			>
				{hint}
			</Alert.Root>
		{/if}
		<RadioGroup.Root
			{value}
			onValueChange={(next) => {
				if (next === "refund" || next === "forfeit") value = next;
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
					<span class="block text-muted-foreground">{options.refund}</span>
				</span>
			</label>
			<label
				class="flex items-start gap-2 rounded-lg border p-3 text-sm has-[[data-state=checked]]:border-primary"
			>
				<RadioGroup.Item value="forfeit" class="mt-0.5" />
				<span>
					<strong>Keep the payment</strong>
					<span class="block text-muted-foreground">{options.forfeit}</span>
				</span>
			</label>
		</RadioGroup.Root>
		{#each issues as issue (issue.message)}
			<Field.Error>{issue.message}</Field.Error>
		{/each}
	</Field.Field>
{/if}
