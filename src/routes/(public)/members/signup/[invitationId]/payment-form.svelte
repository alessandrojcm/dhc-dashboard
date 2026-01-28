<script lang="ts">
import * as Field from "$lib/components/ui/field";
import dayjs from "dayjs";
import { Input } from "$lib/components/ui/input";
import { Button } from "$lib/components/ui/button";
import { parsePhoneNumberFromString } from "libphonenumber-js/min";
import { ArrowRightIcon } from "lucide-svelte";
import {
	loadStripe,
	type StripeElements,
	type StripeElementsOptions,
	type StripePaymentElement,
} from "@stripe/stripe-js";
import { PUBLIC_STRIPE_KEY } from "$env/static/public";
import { toast } from "svelte-sonner";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import { onMount, tick } from "svelte";
import { goto } from "$app/navigation";
import { resolve } from "$app/paths";
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
let showThanks = $state(false);
let paymentError = $state<string | null>(null);

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
		showThanks = true;
		paymentError = null;
	} else if (result?.paymentFailed && "error" in result) {
		paymentError = result.error || "Payment failed";
		toast.error(paymentError);
	}
});

const formatedPhone = $derived.by(() =>
	parsePhoneNumberFromString(data.userData.phoneNumber!),
);

onMount(() => {
	loadStripe(PUBLIC_STRIPE_KEY).then((result) => {
		stripe = result;
		elements = stripe?.elements(stripeElementsOptions);
		paymentElement = elements?.create("payment", {
			defaultValues: {
				billingDetails: {
					name: `${data.userData.firstName} ${data.userData.lastName}`,
					email: data.userData.email,
					phone: data.userData.phoneNumber,
				},
			},
		});
		paymentElement?.mount("#payment-element");
	});
});
</script>

{#snippet thanksAlert()}
    <Alert.Root variant="success" class="w-full">
        <Alert.Title>Thank You for Joining!</Alert.Title>
        <Alert.Description>
            Your membership has been successfully processed. Welcome to Dublin Hema Club! You will receive
            a Discord invite by email shortly.
        </Alert.Description>
        <Button onclick={() => goto(resolve('/dashboard'))} class="mt-2 w-fit">Go to Dashboard</Button>
    </Alert.Root>
{/snippet}
{#snippet errorAlert()}
    <Alert.Root variant="destructive" class="w-full mb-4">
        <Alert.Title>Payment Error</Alert.Title>
        <Alert.Description>
            {paymentError}
        </Alert.Description>
        <Button onclick={() => paymentError = null} variant="outline" class="mt-2 w-fit">Try Again</Button>
    </Alert.Root>
{/snippet}
{#if showThanks}
    {@render thanksAlert()}
{:else}
    {#if paymentError}
        {@render errorAlert()}
    {/if}
    <form
            {...processPayment.enhance(async ({form, data,submit}) => {

                // Validate Stripe is ready
                if (!stripe || !elements) {
                    toast.error('Payment system not initialized');
                    return;
                }

                const {error: elementsError} = await elements.submit();
                if (elementsError?.message) {
                    toast.error(elementsError.message);
                    return;
                }

                // Create the confirmation token
                const {error: paymentMethodError, confirmationToken} =
                    await stripe.createConfirmationToken({
                        elements,
                        params: {
                            return_url: window.location.href + '/members/signup'
                        }
                    });

                if (paymentMethodError?.message) {
                    console.error('[PaymentForm] Stripe createConfirmationToken error:', paymentMethodError);
                    toast.error(paymentMethodError.message);
                    return;
                }

                if (!confirmationToken?.id) {
                    console.error('[PaymentForm] No confirmation token received from Stripe');
                    toast.error('Failed to create payment confirmation. Please try again.');
                    return;
                }

                console.log('[PaymentForm] Confirmation token created:', confirmationToken.id);

                // Update the hidden input element directly in the DOM
                // This ensures the value is available when the form serializes for submission
                const tokenInput = form.querySelector<HTMLInputElement>('input[name="stripeConfirmationToken"]');
                const couponInput = form.querySelector<HTMLInputElement>('input[name="couponCode"]');

                if (tokenInput) {
                    tokenInput.value = confirmationToken.id;
                    console.log('[PaymentForm] Updated hidden token input:', tokenInput.value);
                } else {
                    console.error('[PaymentForm] Could not find hidden token input!');
                    toast.error('Form configuration error. Please refresh and try again.');
                    return;
                }

                if (couponInput) {
                    couponInput.value = currentCoupon;
                }

                // Also update the data POJO (for reference)
                data.stripeConfirmationToken = confirmationToken.id;
                data.couponCode = currentCoupon;

                console.log('[PaymentForm] Data before submit:', JSON.stringify(data));

                // Submit the form
                try {
                    console.log('[PaymentForm] Submitting form with token:', confirmationToken.id);
                    await submit();
                    showThanks = true;
                } catch (error) {
                    console.error('[PaymentForm] Form submission error:', error);
                    toast.error('Something went wrong with your payment');
                    paymentError = 'Something has gone wrong with your payment. You have not been charged.'
                }
            })}
            class="space-y-6"
    >
        <div class="grid grid-cols-2 gap-4">
            <div>
                <p>First Name</p>
                <p class="text-sm text-gray-600">{data.userData.firstName}</p>
            </div>
            <div>
                <p>Last Name</p>
                <p class="text-sm text-gray-600">{data.userData.lastName}</p>
            </div>
            <div>
                <p>Email</p>
                <p class="text-sm text-gray-600 break-words">{data.userData.email}</p>
            </div>
            <div>
                <p>Date of Birth</p>
                <p class="text-sm text-gray-600">
                    {dayjs(data.userData.dateOfBirth).format('DD/MM/YYYY')}
                </p>
            </div>
            <div>
                <p>Gender</p>
                <p class="text-sm text-gray-600 capitalize">{data.userData.gender}</p>
            </div>
            <div>
                <p>Pronouns</p>
                <p class="text-sm text-gray-600 capitalize">{data.userData.pronouns}</p>
            </div>
            <div>
                <p>Phone Number</p>
                <p class="text-sm text-gray-600">{formatedPhone?.formatInternational()}</p>
            </div>
            <div>
                <p>Medical Conditions</p>
                <p class="text-sm text-gray-600">
                    {!data.userData.medicalConditions ? 'N/A' : data.userData.medicalConditions}
                </p>
            </div>
        </div>
        <div class="space-y-4">
            <Field.Field>
                {@const fieldProps = processPayment.fields.nextOfKin.as('text')}
                <Field.Label for={fieldProps.name}>Next of Kin</Field.Label>
                <Input
                        {...fieldProps}
                        id={fieldProps.name}
                        placeholder="Full name of your next of kin"
                />
                {#each processPayment.fields.nextOfKin.issues() as issue}
                    <Field.Error>{issue.message}</Field.Error>
                {/each}
            </Field.Field>
            <Field.Field>
                {@const fieldProps = processPayment.fields.nextOfKinNumber.as('tel')}
                <Field.Label for={fieldProps.name}>Next of Kin Phone Number</Field.Label>
                <PhoneInput
                        {...fieldProps}
                        onChange={value => processPayment.fields.nextOfKinNumber.set(value)}
                        id={fieldProps.name}
                        placeholder="Enter your next of kin's phone number"
                />
                {#each processPayment.fields.nextOfKinNumber.issues() as issue}
                    <Field.Error>{issue.message}</Field.Error>
                {/each}
            </Field.Field>
            <p class="prose text-lg text-black">Payment details</p>
            {#if page.params.invitationId}
                <PricingDisplay
                        invitationId={page.params.invitationId}
                        {currentCoupon}
                        {nextMonthlyBillingDate}
                        {nextAnnualBillingDate}
                />
            {/if}
        </div>
        <div class="flex justify-between">
            <Button type="submit" class="ml-auto" disabled={!!processPayment.pending}>
                {#if processPayment.pending}
                    <LoaderCircle/>
                {:else}
                    Sign up
                    <ArrowRightIcon class="ml-2 h-4 w-4"/>
                {/if}
            </Button>
        </div>
        <input type="hidden" {...processPayment.fields.stripeConfirmationToken.as('text')}/>
        <input type="hidden" {...processPayment.fields.couponCode.as('text')}/>
    </form>
{/if}

{#if dev}
    <FormDebug form={processPayment}/>
{/if}
