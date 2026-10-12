<!--
	ALE-382/389/421: one failed refund and its follow-ups, in either refund
	scope — the console's Needs attention or the Waitlist tab's credit
	panel: Retry (a new Stripe refund), Record manual refund and, while the
	credit is available again, Forfeit — each only when Phoenix lists it
	(`availableCommands`). None emails the person.
-->
<script lang="ts">
import type {
	BeginnersWorkshopCarriedFeeCommand,
	BeginnersWorkshopFailedRefundCommand,
} from "@dhc/api-client";
import { AlertTriangle } from "@lucide/svelte";
import type { QueryClient } from "@tanstack/svelte-query";
import type { RefundScope } from "#lib/beginners-workshops/refunds/scope.js";
import {
	type FailedRefund,
	FOLLOW_UP_LABELS,
	failedRefundText,
} from "#lib/beginners-workshops/refunds/wording.js";
import { Button } from "#lib/components/ui/button/index.js";
import { refundSubmit, scopeQueryClient } from "./enhance.js";
import ManualRefundDialog from "./manual-refund-dialog.svelte";
import {
	forfeitCredit,
	forfeitPersonCredit,
	retryPersonRefund,
	retryRefund,
} from "./refunds.remote";

let {
	scope,
	refund,
	availableCommands,
	name = null,
	queryClient,
}: {
	scope: RefundScope;
	refund: FailedRefund & { id: string };
	/** Phoenix's offered commands; only the follow-ups are read. */
	availableCommands: readonly (
		| BeginnersWorkshopFailedRefundCommand
		| BeginnersWorkshopCarriedFeeCommand
	)[];
	/** Who was to be paid back, when the scope knows. */
	name?: string | null;
	/** The Waitlist tab's query client; defaults to the page's. */
	queryClient?: QueryClient;
} = $props();

// The scope is fixed for the component's lifetime.
// svelte-ignore state_referenced_locally
const client = scopeQueryClient(scope, queryClient);

const offers = (command: BeginnersWorkshopFailedRefundCommand) =>
	availableCommands.includes(command);

const retryWorkshop = $derived(
	scope.kind === "workshop" ? retryRefund.for(refund.id) : null,
);
const retryPerson = $derived(
	scope.kind === "person" ? retryPersonRefund.for(refund.id) : null,
);
const forfeitWorkshop = $derived(
	scope.kind === "workshop" ? forfeitCredit.for(refund.id) : null,
);
const forfeitPerson = $derived(
	scope.kind === "person" ? forfeitPersonCredit.for(refund.id) : null,
);
let manualOpen = $state(false);
let error = $state<string | null>(null);

// svelte-ignore state_referenced_locally
const handlers = {
	done: () => (error = null),
	failed: (message: string) => (error = message),
};
// svelte-ignore state_referenced_locally
const retry = refundSubmit(scope, "retry", client, handlers);
// svelte-ignore state_referenced_locally
const forfeit = refundSubmit(scope, "forfeit", client, handlers);
</script>

<div
	class="flex flex-col gap-2 rounded-xl border-2 border-destructive bg-destructive/5 p-3 text-sm"
	data-testid="failed-refund"
>
	<div class="flex flex-wrap items-center gap-3">
		<AlertTriangle class="size-4 shrink-0" />
		<span class="flex-1"
			>{failedRefundText(refund, availableCommands, name)}</span
		>
		{#if offers("retry")}
			{#if retryWorkshop}
				<form {...retryWorkshop.enhance(retry)}>
					{#if scope.kind === "workshop"}
						<input
							{...retryWorkshop.fields.id.as("hidden", scope.workshopId)}
						/>
					{/if}
					<input {...retryWorkshop.fields.refundId.as("hidden", refund.id)} />
					{@render retryButton(!!retryWorkshop.pending)}
				</form>
			{:else if retryPerson}
				<form {...retryPerson.enhance(retry)}>
					{#if scope.kind === "person"}
						<input
							{...retryPerson.fields.waitlistId.as("hidden", scope.waitlistId)}
						/>
					{/if}
					<input {...retryPerson.fields.refundId.as("hidden", refund.id)} />
					{@render retryButton(!!retryPerson.pending)}
				</form>
			{/if}
		{/if}
		{#if offers("manual")}
			<Button
				type="button"
				size="sm"
				variant="outline"
				onclick={() => (manualOpen = true)}>{FOLLOW_UP_LABELS.manual}</Button
			>
		{/if}
		{#if offers("forfeit")}
			{#if forfeitWorkshop}
				<form {...forfeitWorkshop.enhance(forfeit)}>
					{#if scope.kind === "workshop"}
						<input
							{...forfeitWorkshop.fields.id.as("hidden", scope.workshopId)}
						/>
					{/if}
					<input {...forfeitWorkshop.fields.refundId.as("hidden", refund.id)} />
					{@render forfeitButton(!!forfeitWorkshop.pending)}
				</form>
			{:else if forfeitPerson}
				<form {...forfeitPerson.enhance(forfeit)}>
					{#if scope.kind === "person"}
						<input
							{...forfeitPerson.fields.waitlistId.as(
								"hidden",
								scope.waitlistId,
							)}
						/>
					{/if}
					<input {...forfeitPerson.fields.refundId.as("hidden", refund.id)} />
					{@render forfeitButton(!!forfeitPerson.pending)}
				</form>
			{/if}
		{/if}
	</div>
	{#if error}
		<p class="text-destructive" role="alert">{error}</p>
	{/if}
</div>

{#if offers("manual")}
	<ManualRefundDialog
		{scope}
		{refund}
		{name}
		queryClient={client}
		bind:open={manualOpen}
	/>
{/if}

{#snippet retryButton(pending: boolean)}
	<Button type="submit" size="sm" variant="outline" disabled={pending}
		>{FOLLOW_UP_LABELS.retry}</Button
	>
{/snippet}

{#snippet forfeitButton(pending: boolean)}
	<Button
		type="submit"
		size="sm"
		variant="outline"
		class="text-destructive"
		disabled={pending}>{FOLLOW_UP_LABELS.forfeit}</Button
	>
{/snippet}
