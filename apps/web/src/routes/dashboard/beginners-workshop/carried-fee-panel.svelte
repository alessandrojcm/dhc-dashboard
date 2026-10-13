<!--
	ALE-389: the Waitlist tab's Carried Fee panel for one person — the fee, the
	payment it refunds against, a failed refund — with the commands Phoenix
	offers now: Link Stripe payment (an imported fee) is the panel's own;
	Refund credit and Retry / Record manual refund / Forfeit for a failed
	refund are the refund module's, mounted in the person scope (ALE-421).
	Mounted only when a coordinator opens it, so the Waitlist needs no extra
	request until then.
-->
<script lang="ts">
import { personScope } from "#lib/beginners-workshops/refunds/scope.js";
import { formatRefundAmount } from "#lib/beginners-workshops/refunds/wording.js";
import FailedRefundFollowUp from "#lib/components/beginners-workshops/refunds/failed-refund-follow-up.svelte";
import RefundCredit from "#lib/components/beginners-workshops/refunds/refund-credit.svelte";
import { Button } from "#lib/components/ui/button/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import {
	createCarriedFeePanel,
	type CarriedFeeOutcome,
	type CarriedFeePanelDeps,
} from "./carried-fee-panel.svelte.js";

let { waitlistId, deps }: { waitlistId: string; deps?: CarriedFeePanelDeps } =
	$props();

// The person and deps are fixed for the panel's lifetime.
// svelte-ignore state_referenced_locally
const panel = createCarriedFeePanel(() => waitlistId, deps);
// svelte-ignore state_referenced_locally
const scope = personScope(waitlistId);

let paymentIntentId = $state("");
let error = $state<string | null>(null);

const amount = $derived(
	panel.fee?.amountCents
		? formatRefundAmount(panel.fee.amountCents, panel.fee.currency)
		: null,
);

async function settle(outcome: Promise<CarriedFeeOutcome>) {
	const result = await outcome;
	error = result.ok ? null : result.error;
	if (result.ok) paymentIntentId = "";
}
</script>

<div class="flex flex-col gap-2 text-xs" data-testid="carried-fee-panel">
	{#if panel.isLoading}
		<p class="text-muted-foreground">Loading workshop credit…</p>
	{:else if panel.loadError}
		<p class="text-destructive">{panel.loadError}</p>
	{:else if panel.fee}
		{@const fee = panel.fee}
		<p>
			{fee.origin === "deferral"
				? "Payment saved as credit for a later workshop"
				: `Imported from the Waitlist spreadsheet (Paid: “${fee.importedPaidText ?? ""}”)`}{amount
				? ` · ${amount} originally paid`
				: ""}
		</p>
		{#if fee.origin === "import"}
			<p class="text-muted-foreground">
				{fee.stripePaymentIntentId
					? `Stripe payment ${fee.stripePaymentIntentId}`
					: "Not linked to a Stripe payment yet — link it before it can be refunded."}
			</p>
		{/if}

		{#if fee.failedRefund}
			<FailedRefundFollowUp
				{scope}
				refund={{ ...fee.failedRefund, carriedFee: true }}
				availableCommands={fee.availableCommands}
				queryClient={deps?.queryClient}
			/>
		{/if}

		{#if panel.can("refund")}
			<div class="flex flex-wrap items-center gap-2">
				<RefundCredit {scope} {amount} queryClient={deps?.queryClient} />
			</div>
		{/if}

		{#if panel.can("link_payment")}
			<form
				class="flex flex-col gap-1"
				onsubmit={(event) => {
					event.preventDefault();
					settle(panel.linkPayment(paymentIntentId));
				}}
			>
				<Label for={`payment-intent-${waitlistId}`}>
					Stripe payment id (pi_…)
				</Label>
				<p class="text-muted-foreground">
					Find the original payment in Stripe and copy its payment ID, starting
					with pi_. This lets you refund the imported credit to the right
					payment.
				</p>
				<div class="flex gap-2">
					<Input
						id={`payment-intent-${waitlistId}`}
						bind:value={paymentIntentId}
						placeholder="pi_…"
						autocomplete="off"
					/>
					<Button
						type="submit"
						size="sm"
						disabled={panel.pending || !paymentIntentId.trim()}
						>Link payment</Button
					>
				</div>
			</form>
		{/if}

		{#if error}
			<p class="text-destructive" role="alert">{error}</p>
		{/if}
	{/if}
</div>
