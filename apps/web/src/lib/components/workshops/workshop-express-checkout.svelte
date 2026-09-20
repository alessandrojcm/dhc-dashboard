<script lang="ts">
import {
	loadStripe,
	type Stripe,
	type StripeElements,
	type StripeElementsOptionsClientSecret,
	type StripePaymentElement,
} from "@stripe/stripe-js";
import { PUBLIC_STRIPE_KEY } from "$env/static/public";
import { browser } from "$app/environment";
import { onDestroy, tick, untrack } from "svelte";
import { createMutation, useQueryClient } from "@tanstack/svelte-query";
import { fromPromise } from "xstate";
import { useMachine } from "@xstate/svelte";
import {
	workshopsCompleteRegistrationMutation,
	workshopsCreateRegistrationPaymentIntentMutation,
	workshopsListQueryKey,
} from "@dhc/api-client";
import { apiErrorDetail } from "$lib/api-error";
import WorkshopCheckoutView from "./workshop-checkout-view.svelte";
import {
	workshopCheckoutMachine,
	type WorkshopCheckoutState,
} from "./workshop-checkout-machine";

interface Props {
	workshopId: string;
	workshopTitle: string;
	amount: number; // in cents
	customerId?: string;
	onSuccess?: () => void;
	onCancel?: () => void;
}

let {
	workshopId,
	workshopTitle,
	amount,
	customerId,
	onSuccess,
	onCancel,
}: Props = $props();

const stripeElementsOptions: StripeElementsOptionsClientSecret = {
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

// Stripe browser objects are UI adapters owned by this component; the machine
// only ever sees their outcomes. Do not put them on the snapshot.
let stripe: Stripe | null = null;
let elements: StripeElements | null = null;
let stripePaymentElement: StripePaymentElement | null = null;
let paymentElementMounted = false;
let paymentElementContainer: HTMLDivElement | null = $state(null);

const queryClient = useQueryClient();
const createPaymentIntent = createMutation(() => ({
	...workshopsCreateRegistrationPaymentIntentMutation(),
}));
const completeRegistration = createMutation(() => ({
	...workshopsCompleteRegistrationMutation(),
}));

function actorMessage(cause: unknown, fallback: string): string {
	return (
		apiErrorDetail(cause) ??
		(cause instanceof Error && cause.message ? cause.message : fallback)
	);
}

function teardownPaymentElement() {
	if (stripePaymentElement && paymentElementMounted) {
		stripePaymentElement.unmount();
		paymentElementMounted = false;
	}
	stripePaymentElement = null;
	elements = null;
}

const { snapshot, send } = useMachine(
	workshopCheckoutMachine.provide({
		actors: {
			loadStripe: fromPromise(async () => {
				// The dialog only mounts this on the client; hang if SSR ever renders it.
				if (!browser) await new Promise<never>(() => {});
				const loaded = await loadStripe(PUBLIC_STRIPE_KEY);
				if (!loaded) throw new Error("Failed to load Stripe");
				stripe = loaded;
			}),
			createPaymentIntent: fromPromise(async ({ input }) => {
				try {
					const result = await createPaymentIntent.mutateAsync({
						path: { workshopId: input.workshopId },
						body: input.customerId ? { customerId: input.customerId } : {},
					});
					return result.data;
				} catch (cause) {
					throw new Error(actorMessage(cause, "Failed to initialize payment"));
				}
			}),
			preparePaymentElement: fromPromise(async ({ input, signal }) => {
				if (!stripe) throw new Error("Failed to load Stripe");
				await tick();
				const container = paymentElementContainer;
				if (!container) {
					throw new Error("Failed to initialize payment");
				}
				teardownPaymentElement();
				if (signal.aborted) {
					throw new DOMException("Aborted", "AbortError");
				}

				elements = stripe.elements({
					...stripeElementsOptions,
					clientSecret: input.clientSecret,
				});
				stripePaymentElement = elements.create("payment", {
					layout: "tabs",
				});

				await new Promise<void>((resolve, reject) => {
					const onAbort = () => {
						teardownPaymentElement();
						reject(new DOMException("Aborted", "AbortError"));
					};
					signal.addEventListener("abort", onAbort, { once: true });
					stripePaymentElement?.on("ready", () => {
						signal.removeEventListener("abort", onAbort);
						resolve();
					});
					stripePaymentElement?.mount(container);
					paymentElementMounted = true;
				});
			}),
			confirmPayment: fromPromise(async () => {
				if (!stripe || !elements) {
					throw new Error("Failed to initialize payment");
				}
				const { error } = await stripe.confirmPayment({
					elements,
					confirmParams: {
						return_url: `${window.location.origin}/dashboard/my-workshops`,
					},
					redirect: "if_required",
				});
				if (error?.message) throw new Error(error.message);
			}),
			completeRegistration: fromPromise(async ({ input }) => {
				try {
					await completeRegistration.mutateAsync({
						path: { workshopId: input.workshopId },
						body: { paymentIntentId: input.paymentIntentId },
					});
				} catch (cause) {
					throw new Error(actorMessage(cause, "Registration failed"));
				}
			}),
		},
		actions: {
			notifySuccess: () => {
				teardownPaymentElement();
				queryClient.invalidateQueries({ queryKey: workshopsListQueryKey() });
				onSuccess?.();
			},
			notifyCancel: () => {
				teardownPaymentElement();
				onCancel?.();
			},
		},
	}),
	// Input is fixed for this mount; the parent remounts when the workshop changes.
	{ input: untrack(() => ({ workshopId, customerId })) },
);

onDestroy(teardownPaymentElement);

// SAFETY: the machine is flat, so snapshot.value is always one of the states.
const machineState = $derived($snapshot.value as WorkshopCheckoutState);
const failure = $derived($snapshot.context.failure);
</script>

<WorkshopCheckoutView
	state={machineState}
	{failure}
	{workshopTitle}
	{amount}
	onconfirm={() => send({ type: "CONFIRM" })}
	onretry={() => send({ type: "RETRY" })}
	oncancel={onCancel ? () => send({ type: "CANCEL" }) : undefined}
>
	{#snippet paymentElement()}
		<div
			{@attach (node) => {
				paymentElementContainer = node;
				return () => {
					paymentElementContainer = null;
				};
			}}
		></div>
	{/snippet}
</WorkshopCheckoutView>
