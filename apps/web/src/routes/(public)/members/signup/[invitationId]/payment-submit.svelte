<script lang="ts">
import { ArrowRightIcon } from "@lucide/svelte";
import * as Alert from "$lib/components/ui/alert";
import { Button } from "$lib/components/ui/button";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import {
	paymentSubmitPresentation,
	type PaymentFailure,
	type PaymentMachineState,
} from "$lib/invitation-acceptance/payment-machine";

/**
 * Presentational half of the payment step: renders one intentional UI per
 * `paymentMachine` state. It owns no state of its own — the host component
 * feeds it the machine snapshot and receives the user's intent back as events.
 */
const {
	state,
	failure,
	complimentary,
	verifyAgainHref,
	onsubmit,
	onretry,
}: {
	state: PaymentMachineState;
	failure: PaymentFailure | undefined;
	complimentary: boolean;
	verifyAgainHref: string;
	onsubmit: () => void;
	onretry: () => void;
} = $props();

const presentation = $derived(paymentSubmitPresentation[state]);
</script>

{#if state === "expired"}
	<Alert.Root variant="destructive" class="mb-4 w-full">
		<Alert.Title>Verification expired</Alert.Title>
		<Alert.Description>
			{failure?.message ??
				"Invitation verification has expired. Please verify again."}
		</Alert.Description>
		<Button href={verifyAgainHref} variant="outline" class="mt-2 w-fit">
			Verify again
		</Button>
	</Alert.Root>
{:else if state === "unavailable"}
	<Alert.Root variant="destructive" class="mb-4 w-full">
		<Alert.Title>Payment form unavailable</Alert.Title>
		<Alert.Description>
			{failure?.message ?? "The payment form could not be loaded."}
		</Alert.Description>
		<Button onclick={onretry} variant="outline" class="mt-2 w-fit">
			Try again
		</Button>
	</Alert.Root>
{:else if state === "failed" && failure}
	<Alert.Root variant="destructive" class="mb-4 w-full">
		<Alert.Title>Payment Error</Alert.Title>
		<Alert.Description>{failure.message}</Alert.Description>
	</Alert.Root>
{/if}

<div class="flex flex-col items-end gap-3 border-t border-border/70 pt-6">
	<Button
		type="submit"
		class="w-full sm:w-auto"
		size="lg"
		disabled={presentation.disabled}
		aria-busy={presentation.busy}
		onclick={(event) => {
			event.preventDefault();
			onsubmit();
		}}
	>
		{#if presentation.busy}
			<LoaderCircle />
		{:else}
			{complimentary ? "Complete signup" : "Sign up"}
			<ArrowRightIcon class="ml-2 h-4 w-4" />
		{/if}
	</Button>
	<p
		role="status"
		aria-live="polite"
		class="text-sm text-muted-foreground"
		data-payment-state={state}
	>
		{presentation.status ?? ""}
	</p>
</div>
