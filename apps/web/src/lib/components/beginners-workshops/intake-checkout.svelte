<!--
	ALE-447: the Intake page's embedded Checkout. `intakeCheckoutMachine` owns
	the lifecycle; this component only supplies the widget (factory and
	container) and Phoenix's confirmation, and renders the machine's view.
-->
<script lang="ts">
import { useMachine } from "@xstate/svelte";
import { onMount, untrack } from "svelte";
import { fromPromise } from "xstate";
import { createIntakeCheckout } from "./intake-checkout-sdk.js";
import {
	intakeCheckoutMachine,
	intakeCheckoutView,
} from "./intake-checkout-machine.js";
import * as Alert from "#lib/components/ui/alert/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import {
	embeddedCheckoutWidget,
	type EmbeddedCheckoutFactory,
} from "#lib/stripe/embedded-checkout-widget.js";

let {
	clientSecret,
	onComplete,
	createCheckout = createIntakeCheckout,
}: {
	clientSecret: string;
	/** Asks Phoenix for the outcome; Stripe's callback alone never means paid. */
	onComplete: () => Promise<void>;
	createCheckout?: EmbeddedCheckoutFactory;
} = $props();

let container: HTMLDivElement | undefined = $state();

// The page keys this component by client secret, so the session and the
// factory are fixed for the actor's lifetime.
const { snapshot, send } = useMachine(
	intakeCheckoutMachine.provide({
		actors: {
			widget: embeddedCheckoutWidget(
				untrack(() => createCheckout),
				() => container,
			),
			confirm: fromPromise(() => onComplete()),
		},
	}),
	{ input: untrack(() => ({ clientSecret })) },
);

onMount(() => send({ type: "MOUNTED" }));

const view = $derived(intakeCheckoutView($snapshot));
</script>

<section aria-label="Secure payment" aria-busy={!!view.status} class="w-full">
	{#if view.status}
		<p role="status" class="py-4 text-sm text-muted-foreground">
			{view.status}
		</p>
	{/if}
	{#if view.failure}
		<Alert.Root variant="destructive" class="mb-3">
			<Alert.Description>{view.failure}</Alert.Description>
		</Alert.Root>
	{/if}
	{#if view.retry}
		<Button onclick={() => send({ type: "RETRY" })}>{view.retry}</Button>
	{/if}
	<div bind:this={container}></div>
</section>
