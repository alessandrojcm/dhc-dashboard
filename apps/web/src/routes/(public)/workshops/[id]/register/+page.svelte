<script lang="ts">
import Dinero from "dinero.js";
import {
	formatDublinDateLong,
	formatDublinTime12h,
} from "#lib/club-calendar.js";
import { destinationLines, directionsHref } from "#lib/destinations.js";
import * as Alert from "#lib/components/ui/alert/index.js";
import * as Card from "#lib/components/ui/card/index.js";
import WorkshopRegistrationCheckout from "#lib/components/workshops/workshop-registration-checkout.svelte";
import type { PageData } from "./$types";

const { data }: { data: PageData } = $props();
const workshop = $derived(data.workshop);

const formattedDate = $derived.by(() => {
	return formatDublinDateLong(workshop.start_date);
});

const formattedTime = $derived.by(() => {
	return `${formatDublinTime12h(workshop.start_date)} - ${formatDublinTime12h(workshop.end_date)}`;
});

// ALE-440: the optional destination text and a safe external directions
// link beside the familiar location label.
const destinationFacts = $derived({
	destinationText: workshop.destination_text,
	destinationProvider: workshop.destination_provider,
	destinationPlaceId: workshop.destination_place_id,
});
const destinationDetail = $derived(destinationLines(destinationFacts));
const destinationHref = $derived(
	directionsHref(destinationFacts, workshop.location),
);

const formattedPrice = $derived.by(() => {
	return Dinero({
		amount: workshop.price_non_member,
		currency: "EUR",
	}).toFormat();
});
</script>

<svelte:head>
	<title>Workshop registration</title>
</svelte:head>

<div id="workshop-registration" class="w-full py-6 sm:py-8">
	<div class="mx-auto max-w-6xl">
		<Card.Root>
			<Card.Header class="px-4 pb-4 sm:px-6 sm:pb-6">
				<Card.Title class="text-2xl sm:text-3xl"
					>Workshop registration</Card.Title
				>
				<Card.Description>
					Review workshop details and complete your registration below.
				</Card.Description>
			</Card.Header>
			<Card.Content class="px-4 pt-0 sm:px-6">
				<div
					class="grid gap-6 2xl:grid-cols-[minmax(18rem,20rem)_minmax(0,1fr)] 2xl:items-start"
				>
					<div class="min-w-0 space-y-4">
						<div class="rounded-lg border bg-muted/20 p-4 sm:p-5">
							<h2 class="text-lg font-semibold text-foreground">
								{workshop.title}
							</h2>

							<div
								class="mt-4 grid grid-cols-1 gap-3 text-sm sm:grid-cols-2 2xl:grid-cols-1"
							>
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
									{#if destinationDetail.length > 0}
										<p class="text-muted-foreground">
											{destinationDetail.join(" · ")}
										</p>
									{/if}
									{#if destinationHref}
										<a
											href={destinationHref}
											target="_blank"
											rel="noopener noreferrer"
											class="mt-1 inline-flex min-h-11 items-center gap-1.5 text-sm font-medium text-primary underline-offset-4 hover:underline"
										>
											Get directions
										</a>
									{/if}
								</div>
								<div>
									<p class="font-medium text-foreground">Price</p>
									<p class="text-muted-foreground">{formattedPrice}</p>
								</div>
							</div>

							{#if workshop.description}
								<p class="mt-4 text-sm text-muted-foreground leading-relaxed">
									{workshop.description}
								</p>
							{/if}
						</div>
					</div>

					<div class="min-w-0 space-y-3">
						{#key data.checkoutSessionId}
							<WorkshopRegistrationCheckout
								clientSecret={data.checkoutClientSecret}
							/>
						{/key}

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
:global(.public-shell main:has(#workshop-registration)) {
	padding-inline: 0.75rem;
}

:global(.public-shell main:has(#workshop-registration) > div) {
	max-width: none;
}

:global(#workshop-checkout iframe) {
	max-width: 100%;
}
</style>
