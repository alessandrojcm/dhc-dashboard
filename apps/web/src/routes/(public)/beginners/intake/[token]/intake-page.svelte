<!--
	ALE-381: the person's Intake page. Everything shown is Phoenix's safe
	view; the one action is Phoenix's too. Pay mounts embedded Checkout;
	"Check again" and the
	payment-in-progress refresh reload Phoenix's view. A Carried Fee holder
	(ALE-388) gets "Confirm my place" instead of Pay. No self-service
	decline or withdraw: replies to the email go through a coordinator.
-->
<script lang="ts">
import { tick } from "svelte";
import type { BeginnersIntakePage } from "@dhc/api-client";
import { CalendarDays, Clock, MapPin, RefreshCw } from "@lucide/svelte";
import { goto, invalidateAll } from "$app/navigation";
import IntakeCheckout from "#lib/components/beginners-workshops/intake-checkout.svelte";
import { formatDublinInstant } from "#lib/beginners-workshops/console.js";
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
	startPayment = () => paymentForm.submit(),
}: {
	page: BeginnersIntakePage;
	token: string;
	refresh?: () => void;
	refreshMs?: number;
	startPayment?: () => Promise<boolean>;
} = $props();

const formId = $props.id();
const paymentForm = startIntakePayment.for(formId);
const confirmForm = confirmIntakePlace.for(formId);
const copy = $derived(intakeCopy(page));
const details = $derived(intakeDetails(page));
const actionLabel = $derived(intakeActionLabel(page));
const checkout = $derived(startsCheckout(page));
const confirms = $derived(confirmsWithCarriedFee(page));
const payment = $derived(paymentForm.result?.ok ? paymentForm.result : null);
let requestFailed = $state(false);
const refusal = $derived.by(() => {
	const result = confirms ? confirmForm.result : paymentForm.result;
	if (result?.ok) return null;
	return result && !result.ok
		? result.error
		: requestFailed
			? "Payment is unavailable right now. Please try again shortly."
			: null;
});

// Opening the email link opens payment too. POST still takes the Seat Hold;
// the page's GET never reserves a place. A live hold resumes the same session.
let initiated = false;
$effect(() => {
	if (!checkout || initiated) return;
	initiated = true;
	void openPayment();
});

async function openPayment() {
	await tick(); // The remote form must be attached before programmatic submit.
	try {
		await startPayment();
	} catch {
		requestFailed = true;
	}
}

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
		{#if page.action === "pay" && page.paymentCutoff}
			<Card.Content>
				<p class="text-sm text-muted-foreground">
					Payment deadline: {formatDublinInstant(page.paymentCutoff)}
				</p>
			</Card.Content>
		{/if}
		<Card.Footer>
			{#if checkout && payment}
				{#key payment.clientSecret}
					<IntakeCheckout
						clientSecret={payment.clientSecret}
						onComplete={() =>
							goto(`?session_id=${encodeURIComponent(payment.sessionId)}`)}
					/>
				{/key}
			{:else if checkout}
				{#if !refusal}
					<p role="status" class="py-4 text-sm text-muted-foreground">
						Loading secure payment…
					</p>
				{/if}
				<form {...paymentForm} class="w-full" hidden={!refusal}>
					<input {...paymentForm.fields.token.as("hidden", token)} />
					<Button
						type="submit"
						class="w-full"
						disabled={!!paymentForm.pending}
						aria-busy={!!paymentForm.pending}
					>
						{paymentForm.pending ? "Loading secure payment…" : "Try again"}
					</Button>
				</form>
			{:else if confirms}
				<form {...confirmForm} class="w-full">
					<input {...confirmForm.fields.token.as("hidden", token)} />
					<Button type="submit" class="w-full" disabled={!!confirmForm.pending}>
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
