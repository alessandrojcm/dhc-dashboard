<script lang="ts">
import { onMount } from "svelte";
import {
	createIntakeCheckout,
	type IntakeCheckoutFactory,
	type IntakeCheckoutWidget,
} from "./intake-checkout-sdk.js";
import * as Alert from "#lib/components/ui/alert/index.js";
import { Button } from "#lib/components/ui/button/index.js";

let {
	clientSecret,
	onComplete,
	createCheckout = createIntakeCheckout,
}: {
	clientSecret: string;
	onComplete: () => Promise<void>;
	createCheckout?: IntakeCheckoutFactory;
} = $props();

let container: HTMLDivElement | undefined = $state();
let loading = $state(true);
let failed = $state(false);
let checkout: IntakeCheckoutWidget | undefined;
let disposed = false;

async function mountCheckout() {
	loading = true;
	failed = false;
	try {
		const embedded = await createCheckout({
			clientSecret,
			onComplete: () => {
				if (!disposed) void complete();
			},
		});
		if (disposed) {
			embedded.destroy();
			return;
		}
		checkout = embedded;
		if (container) checkout.mount(container);
	} catch {
		// Stripe errors may contain credentials; show only fixed safe copy.
		checkout?.destroy();
		checkout = undefined;
		if (!disposed) failed = true;
	} finally {
		if (!disposed) loading = false;
	}
}

let completed = $state(false);
async function complete() {
	completed = true;
	checkout?.destroy();
	checkout = undefined;
	loading = true;
	failed = false;
	try {
		// Phoenix retrieves the session and decides the outcome. Stripe's
		// browser callback alone never means the workshop place is paid.
		await onComplete();
	} catch {
		if (!disposed) failed = true;
	} finally {
		if (!disposed) loading = false;
	}
}

onMount(() => {
	void mountCheckout();
	return () => {
		disposed = true;
		checkout?.destroy();
	};
});
</script>

<section aria-label="Secure payment" aria-busy={loading} class="w-full">
	{#if loading}
		<p role="status" class="py-4 text-sm text-muted-foreground">
			{completed ? "Confirming your payment…" : "Loading secure payment…"}
		</p>
	{/if}
	{#if failed}
		<Alert.Root variant="destructive" class="mb-3">
			<Alert.Description>
				{completed
					? "We couldn't check your payment yet. Check again — don't pay twice."
					: "We couldn't load secure payment. Please try again."}
			</Alert.Description>
		</Alert.Root>
		<Button
			onclick={() => (completed ? complete() : mountCheckout())}
			disabled={loading}
		>
			{completed ? "Check payment" : "Try again"}
		</Button>
	{/if}
	<div bind:this={container}></div>
</section>
