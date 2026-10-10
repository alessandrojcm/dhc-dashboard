<!--
	ALE-381: the person's Intake page. Everything shown is Phoenix's safe
	view; the one action is Phoenix's too. Pay goes through the remote form,
	which redirects to Stripe Checkout; "Check again" and the
	payment-in-progress refresh reload Phoenix's view. A Carried Fee holder
	(ALE-388) gets "Confirm my place" instead of Pay. No self-service
	decline or withdraw: replies to the email go through a coordinator.
-->
<script lang="ts">
import type { BeginnersIntakePage } from "@dhc/api-client";
import { CalendarDays, Clock, MapPin, RefreshCw } from "@lucide/svelte";
import { invalidateAll } from "$app/navigation";
import {
	confirmsWithCarriedFee,
	intakeActionLabel,
	intakeCopy,
	intakeDetails,
	REFRESH_MS,
	startsCheckout,
} from "#lib/beginners-workshops/intake-page.js";
import * as Alert from "#lib/components/ui/alert/index.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Card from "#lib/components/ui/card/index.js";
import { confirmIntakePlace, startIntakePayment } from "./intake.remote";

let {
	page,
	token,
	refresh = () => void invalidateAll(),
	refreshMs = REFRESH_MS,
}: {
	page: BeginnersIntakePage;
	token: string;
	refresh?: () => void;
	refreshMs?: number;
} = $props();

const copy = $derived(intakeCopy(page));
const details = $derived(intakeDetails(page));
const actionLabel = $derived(intakeActionLabel(page));
const checkout = $derived(startsCheckout(page));
const confirms = $derived(confirmsWithCarriedFee(page));
const refusal = $derived.by(() => {
	const result = confirms
		? confirmIntakePlace.result
		: startIntakePayment.result;
	return result && !result.ok ? result.error : null;
});

// `payment_in_progress` asks Phoenix again until it reports `paid`.
$effect(() => {
	if (page.state !== "payment_in_progress") return;
	const timer = setTimeout(() => refresh(), refreshMs);
	return () => clearTimeout(timer);
});
</script>

<Card.Root class="w-full max-w-lg" data-state={page.state}>
	<Card.Header>
		{#if details?.greeting}
			<p class="text-sm text-muted-foreground">{details.greeting}</p>
		{/if}
		<Card.Title>
			<h1 class="font-heading text-2xl leading-tight">{copy.title}</h1>
		</Card.Title>
		<Card.Description>{copy.body}</Card.Description>
	</Card.Header>

	{#if details}
		<Card.Content class="flex flex-col gap-3">
			<ul class="flex flex-col gap-2 text-sm" aria-label="Workshop">
				<li class="flex items-center gap-2">
					<CalendarDays class="size-4 text-muted-foreground" />{details.date}
				</li>
				<li class="flex items-center gap-2">
					<Clock class="size-4 text-muted-foreground" />{details.time}
				</li>
				<li class="flex items-center gap-2">
					<MapPin class="size-4 text-muted-foreground" />{details.venue}
				</li>
			</ul>
			{#if details.fee}
				<p class="flex items-center gap-2 text-sm">
					Fee <Badge variant={page.state === "paid" ? "secondary" : "outline"}
						>{details.fee}{page.state === "paid" ? " · paid" : ""}</Badge
					>
				</p>
			{/if}
			{#if refusal}
				<Alert.Root variant="destructive">
					<Alert.Description>{refusal}</Alert.Description>
				</Alert.Root>
			{/if}
		</Card.Content>
	{/if}

	{#if actionLabel}
		<Card.Footer>
			{#if checkout}
				<form {...startIntakePayment} class="w-full">
					<input {...startIntakePayment.fields.token.as("hidden", token)} />
					<Button
						type="submit"
						class="w-full"
						disabled={!!startIntakePayment.pending}
					>
						{actionLabel}
					</Button>
				</form>
			{:else if confirms}
				<form {...confirmIntakePlace} class="w-full">
					<input {...confirmIntakePlace.fields.token.as("hidden", token)} />
					<Button
						type="submit"
						class="w-full"
						disabled={!!confirmIntakePlace.pending}
					>
						{actionLabel}
					</Button>
				</form>
			{:else}
				<Button
					variant="outline"
					class="w-full"
					onclick={() => refresh()}
					aria-busy={page.state === "payment_in_progress"}
				>
					<RefreshCw
						class={page.state === "payment_in_progress" ? "animate-spin" : ""}
					/>
					{actionLabel}
				</Button>
			{/if}
		</Card.Footer>
	{/if}
</Card.Root>
