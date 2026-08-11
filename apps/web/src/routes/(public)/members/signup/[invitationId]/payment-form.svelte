<script lang="ts">
import * as Field from "$lib/components/ui/field";
import { Input } from "$lib/components/ui/input";
import { Button, type ButtonProps } from "$lib/components/ui/button";
import { ArrowRightIcon } from "lucide-svelte";
import {
	loadStripe,
	type StripeElements,
	type StripeElementsOptions,
	type StripePaymentElement,
	type StripePaymentElementOptions,
} from "@stripe/stripe-js";
import { PUBLIC_STRIPE_KEY } from "$env/static/public";
import { toast } from "svelte-sonner";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import { onMount } from "svelte";
import * as Alert from "$lib/components/ui/alert";
import PhoneInput from "$lib/components/ui/phone-input.svelte";
import PricingDisplay from "./pricing-display.svelte";
import type { PageServerData } from "./$types";
import { page } from "$app/state";
import { processPayment } from "./data.remote";
import { initForm } from "$lib/utils/init-form.svelte";
import { dev } from "$app/environment";
import FormDebug from "$lib/components/form-debug.svelte";

const { data }: { data: PageServerData } = $props();
let currentCoupon = $state("");

const nextMonthlyBillingDate = $derived(data.nextMonthlyBillingDate);
const nextAnnualBillingDate = $derived(data.nextAnnualBillingDate);
let stripe: Awaited<ReturnType<typeof loadStripe>> | null = $state(null);
let elements: StripeElements | null | undefined = $state(null);
let paymentElement: StripePaymentElement | null | undefined = $state(null);
let paymentError = $state<string | null>(null);
let paymentElementReady = $state(false);
let paymentElementComplete = $state(false);

const stripeElementsOptions: StripeElementsOptions = {
	mode: "setup",
	payment_method_types: ["sepa_debit"],
	currency: "eur",
	paymentMethodCreation: "manual",
	appearance: {
		theme: "flat",
		variables: {
			colorPrimary: "221.2 83.2% 53.3%",
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

// Handle form results
$effect(() => {
	const result = processPayment.result;
	if (result?.paymentFailed === false) {
		paymentError = null;
	} else if (result?.paymentFailed && "error" in result) {
		paymentError = result.error || "Payment failed";
		toast.error(paymentError);
	}
});

onMount(() => {
	loadStripe(PUBLIC_STRIPE_KEY).then((result) => {
		stripe = result;
		elements = stripe?.elements(stripeElementsOptions);
		paymentElement = elements?.create("payment", paymentElementOptions);
		paymentElement?.on("ready", () => {
			paymentElementReady = true;
		});
		paymentElement?.on("change", ({ complete }) => {
			paymentElementComplete = complete;
		});
		paymentElement?.mount("#payment-element");
	});
});

const handleSubmit: ButtonProps["onclick"] = async (e) => {
	e.preventDefault();
	const form = (e.currentTarget as HTMLButtonElement).form;

	// Validate Stripe is ready
	if (!stripe || !elements) {
		toast.error("Payment system not initialized");
		return;
	}

	const { error: elementsError } = await elements.submit();
	if (elementsError?.message) {
		toast.error(elementsError.message);
		return;
	}

	const { error: paymentMethodError, confirmationToken } =
		await stripe.createConfirmationToken({
			elements,
			params: {
				return_url: page.url.toString(),
			},
		});

	if (paymentMethodError?.message) {
		console.error(
			"[PaymentForm] Stripe createConfirmationToken error:",
			paymentMethodError,
		);
		toast.error(paymentMethodError.message);
		return;
	}

	if (!confirmationToken?.id) {
		console.error("[PaymentForm] No confirmation token received from Stripe");
		toast.error("Failed to create payment confirmation. Please try again.");
		return;
	}

	// Update the hidden input element directly in the DOM
	// This ensures the value is available when the form serializes for submission
	processPayment.fields.stripeConfirmationToken.set(confirmationToken.id);
	await processPayment.validate();
	if (form) {
		form.requestSubmit();
	}
};
</script>

{#snippet errorAlert()}
	<Alert.Root variant="destructive" class="w-full mb-4">
		<Alert.Title>Payment Error</Alert.Title>
		<Alert.Description>
			{paymentError}
		</Alert.Description>
	</Alert.Root>
{/snippet}

{#if paymentError}
	{@render errorAlert()}
{/if}

{#each processPayment.fields.stripeConfirmationToken.issues() as issue (issue.message)}
	<Alert.Root variant="destructive" class="w-full mb-4">
		<Alert.Title>Payment Error</Alert.Title>
		<Alert.Description>
			{issue.message}
		</Alert.Description>
	</Alert.Root>
{/each}

<form {...processPayment} class="space-y-6">
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
		<p class="prose text-lg text-black">Payment details</p>
		<svelte:boundary>
			{#if page.params.invitationId}
				<PricingDisplay
					invitationId={page.params.invitationId ?? ""}
					bind:currentCoupon
					{nextMonthlyBillingDate}
					{nextAnnualBillingDate}
				/>
			{/if}
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
	</div>
	<div class="flex justify-between">
		<Button
			type="submit"
			class="ml-auto"
			disabled={!!processPayment.pending || !paymentElementReady}
			onclick={handleSubmit}
		>
			{#if processPayment.pending}
				<LoaderCircle />
			{:else}
				Sign up
				<ArrowRightIcon class="ml-2 h-4 w-4" />
			{/if}
		</Button>
	</div>
	<div
		id="payment-element-state"
		data-ready={paymentElementReady}
		data-complete={paymentElementComplete}
		class="sr-only"
	></div>
	<input
		type="hidden"
		{...processPayment.fields.stripeConfirmationToken.as("text")}
	/>
	<input {...processPayment.fields.couponCode.as("hidden", currentCoupon)} />
</form>

{#if dev}
	<FormDebug form={processPayment} />
{/if}
