<script lang="ts">
import * as Field from "$lib/components/ui/field";
import { Input } from "$lib/components/ui/input";
import { Button } from "$lib/components/ui/button";
import {
	loadStripe,
	type Stripe,
	type StripeElements,
	type StripeElementsOptions,
	type StripePaymentElementOptions,
} from "@stripe/stripe-js";
import { PUBLIC_STRIPE_KEY } from "$env/static/public";
import { toast } from "svelte-sonner";
import { tick } from "svelte";
import { fromPromise } from "xstate";
import { useMachine } from "@xstate/svelte";
import * as Alert from "$lib/components/ui/alert";
import PhoneInput from "$lib/components/ui/phone-input.svelte";
import PricingDisplay from "./pricing-display.svelte";
import PaymentSubmit from "./payment-submit.svelte";
import type { PageServerData } from "./$types";
import { page } from "$app/state";
import { browser } from "$app/environment";
import { processPayment } from "./data.remote";
import { initForm } from "$lib/utils/init-form.svelte";
import { invitationPaths } from "$lib/invitation-acceptance/paths";
import {
	paymentMachine,
	type PaymentMachineState,
} from "$lib/invitation-acceptance/payment-machine";

const { data }: { data: PageServerData } = $props();
let currentCoupon = $state("");

// Machine input is fixed for the component's lifetime: a complimentary
// invitation never mounts Stripe, a paid one always does.
const complimentary = data.complimentary === true;
const nextMonthlyBillingDate = $derived(data.nextMonthlyBillingDate);
const nextAnnualBillingDate = $derived(data.nextAnnualBillingDate);

let formElement: HTMLFormElement | undefined = $state();
let paymentElementComplete = $state(false);

// Stripe browser objects are UI adapters owned by this component; the machine
// only ever sees their outcomes.
let stripe: Stripe | null = null;
let elements: StripeElements | undefined;

const stripeElementsOptions: StripeElementsOptions = {
	mode: "setup",
	payment_method_types: ["sepa_debit"],
	currency: "eur",
	paymentMethodCreation: "manual",
	appearance: {
		theme: "flat",
		variables: {
			colorPrimary: "hsl(221.2, 83.2%, 53.3%)",
			borderRadius: ".5rem",
			fontFamily: "Inter, sans-serif",
			fontSizeBase: "1rem",
			fontSizeSm: "0.875rem",
		},
		rules: {
			".Label": {
				fontWeight: "500",
			},
			".Input": {
				marginTop: ".5rem",
				backgroundColor: "transparent",
				border: "hsl(214.3 31.8% 91.4%) 1px solid",
				borderRadius: "calc(var(--borderRadius) - 2px)",
				fontSize: "var(--fontSizeSm)",
				padding: "0.5rem 0.75rem",
			},
		},
	},
};

const paymentElementOptions: StripePaymentElementOptions = {
	layout: {
		type: "accordion",
		defaultCollapsed: false,
		radios: false,
		spacedAccordionItems: false,
	},
};

// Initialize form with empty values
initForm(processPayment, () => ({
	nextOfKin: "",
	nextOfKinNumber: "",
	stripeConfirmationToken: "",
	couponCode: "",
}));

const { snapshot, send } = useMachine(
	paymentMachine.provide({
		actors: {
			loadPaymentElement: fromPromise(async () => {
				// SSR renders the initializing state; only the browser mounts Stripe.
				// The actor is stopped with the component, so this never settles.
				if (!browser) await new Promise<never>(() => {});
				const loaded = await loadStripe(PUBLIC_STRIPE_KEY);
				if (!loaded) throw new Error("Payment system not initialized");
				stripe = loaded;
				elements = loaded.elements(stripeElementsOptions);
				const paymentElement = elements.create(
					"payment",
					paymentElementOptions,
				);
				paymentElement.on("change", ({ complete }) => {
					paymentElementComplete = complete;
				});
				await new Promise<void>((resolve) => {
					paymentElement.on("ready", () => resolve());
					paymentElement.mount("#payment-element");
				});
			}),
			preparePayment: fromPromise(async ({ input }) => {
				if (input.complimentary) return { confirmationToken: undefined };
				if (!stripe || !elements) {
					throw new Error("Payment system not initialized");
				}

				const { error: elementsError } = await elements.submit();
				if (elementsError?.message) throw new Error(elementsError.message);

				const { error: tokenError, confirmationToken } =
					await stripe.createConfirmationToken({
						elements,
						params: { return_url: page.url.toString() },
					});
				if (tokenError?.message) {
					console.error(
						"[PaymentForm] Stripe createConfirmationToken error:",
						tokenError,
					);
					throw new Error(tokenError.message);
				}
				if (!confirmationToken?.id) {
					console.error(
						"[PaymentForm] No confirmation token received from Stripe",
					);
					throw new Error(
						"Failed to create payment confirmation. Please try again.",
					);
				}

				return { confirmationToken: confirmationToken.id };
			}),
		},
		actions: {
			submitPayment: (_, { confirmationToken }) => {
				processPayment.fields.stripeConfirmationToken.set(
					confirmationToken ?? "",
				);
				// Wait for the remote field update to reach the hidden input before
				// the form serializes its controls for submission.
				void tick().then(() => formElement?.requestSubmit());
			},
		},
	}),
	{ input: { complimentary } },
);

// SAFETY: `paymentMachine` is flat (no nested or parallel states), so its
// snapshot value is always one of `paymentMachineStates`.
const machineState = $derived($snapshot.value as PaymentMachineState);
const failure = $derived($snapshot.context.failure);

$effect(() => {
	if (machineState === "failed" && failure) toast.error(failure.message);
});

// Every submission goes through the machine: a native submit (Enter in a
// field) becomes a payment request, and only the machine's `submitting` state
// reaches the server. The server answers a failed submission with data
// (success and still-pending answers redirect away from this page).
const enhancedForm = processPayment.enhance(async ({ submit }) => {
	if (machineState !== "submitting") {
		send({ type: "PAYMENT_REQUESTED" });
		return;
	}

	try {
		await submit();
	} catch (error) {
		send({
			type: "SUBMISSION_FAILED",
			message:
				error instanceof Error ? error.message : "An unexpected error occurred",
			recoverable: true,
		});
		return;
	}

	const result = processPayment.result;
	if (result?.paymentFailed) {
		send({
			type: "SUBMISSION_FAILED",
			message: result.error || "Payment failed",
			recoverable: result.recoverable,
		});
	}
});
</script>

{#each processPayment.fields.stripeConfirmationToken.issues() as issue (issue.message)}
	<Alert.Root variant="destructive" class="w-full mb-4">
		<Alert.Title>Payment Error</Alert.Title>
		<Alert.Description>
			{issue.message}
		</Alert.Description>
	</Alert.Root>
{/each}

<form {...enhancedForm} bind:this={formElement} class="space-y-7">
	<div class="space-y-4">
		<Field.Field>
			{@const fieldProps = processPayment.fields.nextOfKin.as("text")}
			<Field.Label for={fieldProps.name}>Next of Kin</Field.Label>
			<Input
				{...fieldProps}
				id={fieldProps.name}
				placeholder="Full name of your next of kin"
			/>
			{#each processPayment.fields.nextOfKin.issues() as issue (issue.message)}
				<Field.Error>{issue.message}</Field.Error>
			{/each}
		</Field.Field>
		<Field.Field>
			{@const fieldProps = processPayment.fields.nextOfKinNumber.as("tel")}
			<Field.Label for={fieldProps.name}>Next of Kin Phone Number</Field.Label>
			<PhoneInput
				{...fieldProps}
				onChange={(value) => processPayment.fields.nextOfKinNumber.set(value)}
				id={fieldProps.name}
				placeholder="Enter your next of kin's phone number"
			/>
			{#each processPayment.fields.nextOfKinNumber.issues() as issue (issue.message)}
				<Field.Error>{issue.message}</Field.Error>
			{/each}
		</Field.Field>
		{#if !complimentary}
			<div class="border-t border-border/70 pt-6">
				<p class="font-display text-xl text-foreground">Membership & payment</p>
				<p class="mt-1 text-sm leading-6 text-muted-foreground">
					Review your plan and enter the account used for your membership fee.
				</p>
			</div>
			<svelte:boundary>
				<PricingDisplay
					bind:currentCoupon
					{nextMonthlyBillingDate}
					{nextAnnualBillingDate}
				/>
				{#snippet failed(error, reset)}
					<Alert.Root variant="destructive" class="w-full mb-4">
						<Alert.Title>Error loading pricing information</Alert.Title>
						<Alert.Description>
							{error instanceof Error ? error.message : String(error)}
						</Alert.Description>
						<Button onclick={reset} variant="outline" class="mt-2 w-fit"
							>Try Again</Button
						>
					</Alert.Root>
				{/snippet}
			</svelte:boundary>
		{/if}
	</div>
	<PaymentSubmit
		state={machineState}
		{failure}
		{complimentary}
		verifyAgainHref={invitationPaths.page(page.params.invitationId ?? "")}
		onsubmit={() => send({ type: "PAYMENT_REQUESTED" })}
		onretry={() => send({ type: "RETRY_REQUESTED" })}
	/>
	<div
		id="payment-element-state"
		data-ready={machineState !== "deciding" &&
			machineState !== "initializing" &&
			machineState !== "unavailable"}
		data-complete={paymentElementComplete}
		class="sr-only"
	></div>
	<input
		type="hidden"
		{...processPayment.fields.stripeConfirmationToken.as("text")}
	/>
	<input {...processPayment.fields.couponCode.as("hidden", currentCoupon)} />
</form>
