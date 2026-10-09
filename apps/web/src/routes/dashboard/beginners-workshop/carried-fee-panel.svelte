<!--
	ALE-389: the Waitlist tab's Carried Fee panel for one person — the fee, the
	payment it refunds against, a failed refund — with the commands Phoenix
	offers now: Refund Carried Fee, Link Stripe payment (an imported fee),
	and Retry / Record manual refund / Forfeit for a failed refund. Mounted
	only when a coordinator opens it, so the Waitlist needs no extra request
	until then.
-->
<script lang="ts">
import { formatRefundAmount } from "#lib/beginners-workshops/console.js";
import { Button } from "#lib/components/ui/button/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
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

let confirmingRefund = $state(false);
let paymentIntentId = $state("");
let manualNote = $state("");
let error = $state<string | null>(null);

const amount = $derived(
	panel.fee?.amountCents
		? formatRefundAmount(panel.fee.amountCents, panel.fee.currency)
		: null,
);

async function settle(outcome: Promise<CarriedFeeOutcome>) {
	const result = await outcome;
	error = result.ok ? null : result.error;
	if (result.ok) {
		confirmingRefund = false;
		paymentIntentId = "";
		manualNote = "";
	}
}
</script>

<div class="flex flex-col gap-2 text-xs" data-testid="carried-fee-panel">
	{#if panel.isLoading}
		<p class="text-muted-foreground">Loading the Carried Fee…</p>
	{:else if panel.loadError}
		<p class="text-destructive">{panel.loadError}</p>
	{:else if panel.fee}
		{@const fee = panel.fee}
		<p>
			{fee.origin === "deferral"
				? "Carried from a deferred Beginners' Workshop payment"
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
			<p class="text-destructive" data-testid="carried-fee-failed-refund">
				The refund of {formatRefundAmount(
					fee.failedRefund.amountCents,
					fee.failedRefund.currency,
				)} failed{fee.failedRefund.lastError
					? ` (${fee.failedRefund.lastError})`
					: ""}. The fee is held again: retry the refund, record a manual refund
				if you paid them back another way, or forfeit the fee.
			</p>
		{/if}

		<div class="flex flex-wrap items-center gap-2">
			{#if panel.can("refund")}
				{#if confirmingRefund}
					<span>Refund {amount ?? "the fee"} to the original payment?</span>
					<Button
						size="sm"
						disabled={panel.pending}
						onclick={() => settle(panel.refund())}>Refund</Button
					>
					<Button
						size="sm"
						variant="ghost"
						onclick={() => (confirmingRefund = false)}>Keep it</Button
					>
				{:else}
					<Button
						size="sm"
						variant="outline"
						onclick={() => (confirmingRefund = true)}>Refund Carried Fee</Button
					>
				{/if}
			{/if}
			{#if panel.can("retry")}
				<Button
					size="sm"
					variant="outline"
					disabled={panel.pending}
					onclick={() => settle(panel.retry())}>Retry refund</Button
				>
			{/if}
			{#if panel.can("forfeit")}
				<Button
					size="sm"
					variant="outline"
					class="text-destructive"
					disabled={panel.pending}
					onclick={() => settle(panel.forfeit())}>Forfeit</Button
				>
			{/if}
		</div>

		{#if panel.can("manual")}
			<form
				class="flex flex-col gap-1"
				onsubmit={(event) => {
					event.preventDefault();
					settle(panel.recordManual(manualNote));
				}}
			>
				<Label for={`manual-note-${waitlistId}`}>
					How they were paid back (optional)
				</Label>
				<Textarea
					id={`manual-note-${waitlistId}`}
					bind:value={manualNote}
					maxlength={500}
				/>
				<Button
					type="submit"
					size="sm"
					variant="outline"
					class="self-start"
					disabled={panel.pending}>Record manual refund</Button
				>
			</form>
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
