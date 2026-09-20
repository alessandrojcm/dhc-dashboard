<script lang="ts">
import type { Snippet } from "svelte";
import * as Alert from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import {
	workshopCheckoutPresentation,
	type CheckoutFailure,
	type WorkshopCheckoutState,
} from "./workshop-checkout-machine";

/**
 * Presentational half of workshop express checkout: one intentional UI per
 * `workshopCheckoutMachine` state. It owns no protocol of its own — the host
 * feeds it the machine snapshot and receives CONFIRM / RETRY / CANCEL back.
 */
const {
	state,
	failure,
	workshopTitle,
	amount,
	onconfirm,
	onretry,
	oncancel,
	paymentElement,
}: {
	state: WorkshopCheckoutState;
	failure: CheckoutFailure | undefined;
	workshopTitle: string;
	amount: number;
	onconfirm: () => void;
	onretry: () => void;
	oncancel?: () => void;
	paymentElement?: Snippet;
} = $props();

const presentation = $derived(workshopCheckoutPresentation[state]);
const showForm = $derived(
	!presentation.showRetry &&
		(presentation.showPaymentElement || presentation.confirmBusy),
);
</script>

{#if state === "succeeded"}
	<Alert.Root variant="success" class="w-full">
		<Alert.Title>Registration confirmed</Alert.Title>
		<Alert.Description>
			You are registered for {workshopTitle}. We will send the details by email.
		</Alert.Description>
	</Alert.Root>
{:else if state !== "cancelled"}
	<div class="max-h-[80vh] overflow-y-auto">
		<div class="space-y-4 p-1">
			{#if presentation.showRetry}
				<Alert.Root variant="destructive" class="w-full">
					<Alert.Title>Registration Failed</Alert.Title>
					<Alert.Description>
						{failure?.message ?? "Registration failed"}
					</Alert.Description>
					<div class="mt-2 flex gap-2">
						<Button variant="outline" size="sm" onclick={onretry}>
							Try Again
						</Button>
						{#if oncancel && presentation.showCancel}
							<Button variant="ghost" size="sm" onclick={oncancel}>
								Cancel
							</Button>
						{/if}
					</div>
				</Alert.Root>
			{:else}
				<div class="text-center">
					<h3 class="text-lg font-semibold">Register for {workshopTitle}</h3>
					<p class="text-sm text-muted-foreground">
						Amount: €{(amount / 100).toFixed(2)}
					</p>
				</div>
			{/if}

			{#if presentation.status && !showForm}
				<div class="flex items-center justify-center py-8">
					<LoaderCircle />
					<span class="ml-2">{presentation.status}</span>
				</div>
			{/if}

			{#if showForm && presentation.confirmBusy && presentation.status}
				<div class="flex items-center justify-center py-4">
					<LoaderCircle />
					<span class="ml-2">{presentation.status}</span>
				</div>
			{/if}

			<!-- Keep the Stripe mount point in the DOM across failed → ready retries. -->
			<div class={presentation.showPaymentElement ? "min-h-[200px]" : "hidden"}>
				{@render paymentElement?.()}
			</div>

			{#if showForm}
				<div class="space-y-4">
					<Button
						onclick={onconfirm}
						disabled={presentation.confirmDisabled}
						aria-busy={presentation.confirmBusy}
						class="w-full"
					>
						{#if presentation.confirmBusy}
							<LoaderCircle class="mr-2 h-4 w-4" />
						{/if}
						Complete Payment
					</Button>

					<div class="text-xs text-muted-foreground text-center">
						Secure payment powered by Stripe
					</div>
				</div>
			{/if}
		</div>
	</div>
{/if}

<p
	role="status"
	aria-live="polite"
	class="sr-only"
	data-checkout-state={state}
	data-checkout-stage={failure?.stage ?? ""}
>
	{presentation.status ?? ""}
</p>
