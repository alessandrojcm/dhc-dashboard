<script lang="ts">
import { PUBLIC_STRIPE_KEY } from "$env/static/public";
import { loadStripe, type StripeEmbeddedCheckout } from "@stripe/stripe-js";
import dayjs from "dayjs";
import Dinero from "dinero.js";
import { onMount } from "svelte";
import * as Alert from "$lib/components/ui/alert";
import * as Card from "$lib/components/ui/card";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import type { PageData } from "./$types";

const { data }: { data: PageData } = $props();
const workshop = $derived(data.workshop);

let flowError = $state<string | null>(null);
let checkoutInitializing = $state(true);

const formattedDate = $derived.by(() => {
	return dayjs(workshop.start_date).format("dddd, MMM DD, YYYY");
});

const formattedTime = $derived.by(() => {
	return `${dayjs(workshop.start_date).format("h:mm A")} - ${dayjs(workshop.end_date).format("h:mm A")}`;
});

const formattedPrice = $derived.by(() => {
	return Dinero({
		amount: workshop.price_non_member,
		currency: "EUR",
	}).toFormat();
});

onMount(() => {
	let destroyed = false;
	let embeddedCheckout: StripeEmbeddedCheckout | null = null;

	async function mountEmbeddedCheckout() {
		if (!PUBLIC_STRIPE_KEY) {
			flowError = "Payment is currently unavailable. Please try again later.";
			checkoutInitializing = false;
			return;
		}

		if (typeof data.checkoutClientSecret !== "string") {
			flowError =
				"Failed to initialize checkout. Please refresh and try again.";
			checkoutInitializing = false;
			return;
		}

		try {
			const stripe = await loadStripe(PUBLIC_STRIPE_KEY);

			if (!stripe) {
				flowError =
					"Failed to initialize secure payment. Please refresh and try again.";
				return;
			}

			embeddedCheckout = await stripe.initEmbeddedCheckout({
				clientSecret: data.checkoutClientSecret,
			});

			if (destroyed) {
				embeddedCheckout.destroy();
				return;
			}
			embeddedCheckout.mount("#workshop-checkout");
		} catch (error) {
			flowError =
				error instanceof Error
					? error.message
					: "Failed to initialize checkout. Please try again.";
		} finally {
			checkoutInitializing = false;
		}
	}

	void mountEmbeddedCheckout();

	return () => {
		destroyed = true;
		embeddedCheckout?.destroy();
	};
});
</script>

<svelte:head>
	<title>Workshop registration</title>
</svelte:head>

<div class="container mx-auto px-4 py-8">
	<div class="mx-auto max-w-5xl">
		<Card.Root>
			<Card.Header class="pb-4">
				<Card.Title class="text-2xl">Workshop registration</Card.Title>
				<Card.Description>
					Review workshop details and complete your registration below.
				</Card.Description>
			</Card.Header>
			<Card.Content class="pt-0">
				<div class="grid gap-6 xl:grid-cols-[minmax(0,0.85fr)_minmax(420px,1fr)] xl:items-start">
					<div class="min-w-0 space-y-4">
						<div class="rounded-lg border bg-muted/20 p-4">
							<h2 class="text-lg font-semibold text-foreground">{workshop.title}</h2>

							<div class="mt-4 grid grid-cols-1 gap-3 text-sm sm:grid-cols-2 lg:grid-cols-1">
								<div>
									<p class="font-medium text-foreground">Date</p>
									<p class="text-muted-foreground">{formattedDate}</p>
								</div>
								<div>
									<p class="font-medium text-foreground">Time</p>
									<p class="text-muted-foreground">{formattedTime}</p>
								</div>
								<div>
									<p class="font-medium text-foreground">Location</p>
									<p class="text-muted-foreground">{workshop.location}</p>
								</div>
								<div>
									<p class="font-medium text-foreground">Price</p>
									<p class="text-muted-foreground">{formattedPrice}</p>
								</div>
							</div>

							{#if workshop.description}
								<p class="mt-4 text-sm text-muted-foreground leading-relaxed">{workshop.description}</p>
							{/if}
						</div>
					</div>

					<div class="min-w-0 space-y-3">
						{#if flowError}
							<Alert.Root variant="destructive" class="w-full">
								<Alert.Title>Registration error</Alert.Title>
								<Alert.Description>{flowError}</Alert.Description>
							</Alert.Root>
						{/if}

						{#if checkoutInitializing}
							<div class="flex items-center gap-2 text-sm text-muted-foreground">
								<LoaderCircle class="h-4 w-4" />
								Loading payment form...
							</div>
						{/if}

						<div
							id="workshop-checkout"
							class="h-[70vh] min-h-[460px] max-h-[820px] w-full min-w-0 overflow-y-auto overflow-x-hidden rounded-lg border bg-background"
						></div>

						<p class="text-xs text-muted-foreground">
							A payment receipt will be sent by email after successful checkout.
						</p>
					</div>
				</div>
			</Card.Content>
		</Card.Root>
	</div>
</div>

<style>
	:global(#workshop-checkout iframe) {
		max-width: 100%;
	}
</style>
