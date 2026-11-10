<!--
	ALE-381: the person's Intake page. Everything shown is Phoenix's safe
	view; the one action is Phoenix's too. ALE-447: `intakePaymentMachine`
	owns the orchestration — the automatic payment start, refusal and retry,
	the payment-in-progress refresh and the Carried Fee "Confirm my place"
	alternative (ALE-388) — and the embedded widget's machine owns collection
	and confirmation. The remote forms stay the transport. No self-service
	decline or withdraw: replies to the email go through a coordinator.
-->
<script lang="ts">
import { onMount, tick, untrack } from "svelte";
import type { BeginnersIntakePage } from "@dhc/api-client";
import { CalendarDays, Clock, MapPin, RefreshCw } from "@lucide/svelte";
import { useMachine } from "@xstate/svelte";
import { fromPromise } from "xstate";
import { goto, invalidateAll } from "$app/navigation";
import IntakeCheckout from "#lib/components/beginners-workshops/intake-checkout.svelte";
import { formatDublinInstant } from "#lib/club-calendar.js";
import {
	intakeActionLabel,
	intakeCopy,
	intakeDetails,
	REFRESH_MS,
} from "#lib/beginners-workshops/intake-page.js";
import type { EmbeddedCheckoutFactory } from "#lib/stripe/embedded-checkout-widget.js";
import {
	intakePaymentMachine,
	intakePaymentView,
	type IntakePaymentStart,
} from "#lib/beginners-workshops/intake-payment-machine.js";
import * as Alert from "#lib/components/ui/alert/index.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Card from "#lib/components/ui/card/index.js";
import DestinationAttribution from "#lib/components/destination-attribution.svelte";
import { confirmIntakePlace, startIntakePayment } from "./intake.remote";

let {
	page,
	token,
	refresh = () => void invalidateAll(),
	refreshMs = REFRESH_MS,
	startPayment = submitPayment,
	createCheckout,
}: {
	page: BeginnersIntakePage;
	token: string;
	refresh?: () => void;
	refreshMs?: number;
	startPayment?: () => Promise<IntakePaymentStart>;
	/** The embedded widget's Stripe; the widget's own default when unset. */
	createCheckout?: EmbeddedCheckoutFactory;
} = $props();

const formId = $props.id();
const paymentForm = startIntakePayment.for(formId);
const confirmForm = confirmIntakePlace.for(formId);

// The POST that takes the Seat Hold. Its result is `undefined` while a
// hosted hold from before the embedded migration redirects away.
async function submitPayment(): Promise<IntakePaymentStart> {
	await tick(); // The remote form must be attached before programmatic submit.
	if (!(await paymentForm.submit())) throw new Error("Payment not submitted");
	return paymentForm.result;
}

// The route keys this page by token, so the inputs are fixed for the
// actor's lifetime; later views arrive as `PAGE`.
const { snapshot, send } = useMachine(
	intakePaymentMachine.provide({
		actors: { startPayment: fromPromise(() => startPayment()) },
		actions: { refresh: () => refresh() },
	}),
	{ input: untrack(() => ({ page, refreshMs })) },
);

// Only the mounted browser may start a payment or arm the refresh.
onMount(() => send({ type: "MOUNTED" }));
$effect(() => {
	send({ type: "PAGE", page });
});

const view = $derived(intakePaymentView($snapshot));
const copy = $derived(intakeCopy(page));
const details = $derived(intakeDetails(page));
const actionLabel = $derived(intakeActionLabel(page));
const refusal = $derived.by(() => {
	if (view.footer.kind !== "confirm") return view.refusal;
	const result = confirmForm.result;
	return result && !result.ok ? result.error : null;
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
				<li class="flex items-start gap-2">
					<MapPin class="mt-0.5 size-4 shrink-0 text-muted-foreground" />
					<span class="flex flex-col gap-0.5">
						<span>{details.venue}</span>
						{#if details.destination.length > 0}
							<span class="text-muted-foreground"
								>{details.destination.join(" · ")}</span
							>
						{/if}
						{#if details.attribution}
							<DestinationAttribution credits={details.attribution.credits} />
						{/if}
						{#if details.directionsHref}
							<!-- The page sends no referrer, and this link never carries its token. -->
							<a
								href={details.directionsHref}
								target="_blank"
								rel="noopener noreferrer"
								referrerpolicy="no-referrer"
								class="inline-flex min-h-11 items-center font-medium text-primary underline-offset-4 hover:underline"
								>Get directions</a
							>
						{/if}
					</span>
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
			{#if view.footer.kind === "checkout"}
				{@const session = view.footer.session}
				{#key session.clientSecret}
					<IntakeCheckout
						clientSecret={session.clientSecret}
						{createCheckout}
						onComplete={() =>
							goto(`?session_id=${encodeURIComponent(session.sessionId)}`)}
					/>
				{/key}
			{:else if view.footer.kind === "loading" || view.footer.kind === "retry"}
				{#if view.footer.kind === "loading"}
					<p role="status" class="py-4 text-sm text-muted-foreground">
						Loading secure payment…
					</p>
				{/if}
				<!-- The start's transport: the machine submits it, on mount and on retry. -->
				<form
					{...paymentForm}
					class="w-full"
					hidden={view.footer.kind !== "retry"}
				>
					<input {...paymentForm.fields.token.as("hidden", token)} />
					{#if view.footer.kind === "retry"}
						<Button
							type="button"
							class="w-full"
							disabled={view.footer.busy}
							aria-busy={view.footer.busy}
							onclick={() => send({ type: "RETRY" })}
						>
							{view.footer.busy ? "Loading secure payment…" : view.footer.label}
						</Button>
					{/if}
				</form>
			{:else if view.footer.kind === "confirm"}
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
					onclick={() => send({ type: "REFRESH" })}
					aria-busy={view.footer.inProgress}
				>
					<RefreshCw class={view.footer.inProgress ? "animate-spin" : ""} />
					{actionLabel}
				</Button>
			{/if}
		</Card.Footer>
	{/if}
</Card.Root>
