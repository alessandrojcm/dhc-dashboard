<!--
	ALE-382: one failed refund under Needs attention, with its follow-ups:
	Retry (a new Stripe refund), Record manual refund and, for a Carried Fee's
	refund (ALE-389), Forfeit. None emails the person.
-->
<script lang="ts">
import type { BeginnersWorkshopFailedRefund } from "@dhc/api-client";
import { AlertTriangle } from "@lucide/svelte";
import { toast } from "svelte-sonner";
import { failedRefundText } from "#lib/beginners-workshops/console.js";
import { Button } from "#lib/components/ui/button/index.js";
import { forfeitCarriedFee, retryRefund } from "./console.remote";
import ManualRefundDialog from "./manual-refund-dialog.svelte";

let {
	workshopId,
	refund,
}: { workshopId: string; refund: BeginnersWorkshopFailedRefund } = $props();

const retry = $derived(retryRefund.for(refund.id));
const forfeit = $derived(forfeitCarriedFee.for(refund.id));
let manualOpen = $state(false);
</script>

<div
	class="flex flex-wrap items-center gap-3 rounded-xl border-2 border-destructive bg-destructive/5 p-3 text-sm"
	data-testid="failed-refund"
>
	<AlertTriangle class="size-4 shrink-0" />
	<span class="flex-1">{failedRefundText(refund)}</span>
	<form
		{...retry.enhance(async (instance) => {
			if (!(await instance.submit())) return;
			const result = instance.result;
			if (result?.ok) toast.success("Refund sent to Stripe again");
			else if (result) toast.error(result.error);
		})}
	>
		<input {...retry.fields.id.as("hidden", workshopId)} />
		<input {...retry.fields.refundId.as("hidden", refund.id)} />
		<Button type="submit" size="sm" variant="outline" disabled={!!retry.pending}
			>Retry</Button
		>
	</form>
	<Button
		type="button"
		size="sm"
		variant="outline"
		onclick={() => (manualOpen = true)}>Record manual refund</Button
	>
	{#if refund.carriedFee}
		<form
			{...forfeit.enhance(async (instance) => {
				if (!(await instance.submit())) return;
				const result = instance.result;
				if (result?.ok) toast.success("Carried Fee forfeited");
				else if (result) toast.error(result.error);
			})}
		>
			<input {...forfeit.fields.id.as("hidden", workshopId)} />
			<input {...forfeit.fields.refundId.as("hidden", refund.id)} />
			<Button
				type="submit"
				size="sm"
				variant="outline"
				class="text-destructive"
				disabled={!!forfeit.pending}>Forfeit</Button
			>
		</form>
	{/if}
</div>

<ManualRefundDialog {workshopId} {refund} bind:open={manualOpen} />
