<!--
	ALE-447: public regular-Workshop registration's embedded Checkout.
	`workshopRegistrationCheckoutMachine` owns the lifecycle; this component
	only supplies the widget (factory and container) and renders the
	machine's view.
-->
<script lang="ts">
import { useMachine } from "@xstate/svelte";
import { onMount, untrack } from "svelte";
import { PUBLIC_STRIPE_KEY } from "$app/env/public";
import { createWorkshopRegistrationCheckout } from "./workshop-registration-checkout-sdk.js";
import {
	workshopRegistrationCheckoutMachine,
	workshopRegistrationCheckoutView,
} from "./workshop-registration-checkout-machine.js";
import * as Alert from "#lib/components/ui/alert/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import LoaderCircle from "#lib/components/ui/loader-circle.svelte";
import {
	embeddedCheckoutWidget,
	type EmbeddedCheckoutFactory,
} from "#lib/stripe/embedded-checkout-widget.js";

let {
	clientSecret,
	stripeConfigured = !!PUBLIC_STRIPE_KEY,
	createCheckout = createWorkshopRegistrationCheckout,
}: {
	clientSecret: string | null | undefined;
	stripeConfigured?: boolean;
	createCheckout?: EmbeddedCheckoutFactory;
} = $props();

let container: HTMLDivElement | undefined = $state();

// The page keys this component by Checkout Session id, so the session and
// the factory are fixed for the actor's lifetime.
const { snapshot, send } = useMachine(
	workshopRegistrationCheckoutMachine.provide({
		actors: {
			widget: embeddedCheckoutWidget(
				untrack(() => createCheckout),
				() => container,
			),
		},
	}),
	{ input: untrack(() => ({ clientSecret, stripeConfigured })) },
);

onMount(() => send({ type: "MOUNTED" }));

const view = $derived(workshopRegistrationCheckoutView($snapshot));
</script>

{#if view.failure}
	<Alert.Root variant="destructive" class="w-full">
		<Alert.Title>Registration error</Alert.Title>
		<Alert.Description>{view.failure}</Alert.Description>
	</Alert.Root>
{/if}

{#if view.retry}
	<Button variant="outline" onclick={() => send({ type: "RETRY" })}>
		{view.retry}
	</Button>
{/if}

{#if view.status}
	<div class="flex items-center gap-2 text-sm text-muted-foreground">
		<LoaderCircle class="h-4 w-4" />
		{view.status}
	</div>
{/if}

<div
	id="workshop-checkout"
	bind:this={container}
	class="h-[70vh] min-h-[460px] max-h-[820px] w-full min-w-0 overflow-y-auto overflow-x-hidden rounded-lg border bg-background"
></div>
