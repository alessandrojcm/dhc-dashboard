<script lang="ts">
import {
	loadStripe,
	type StripeElements,
	type StripeElementsOptionsClientSecret,
	type StripePaymentElement,
} from "@stripe/stripe-js";
import { createMutation, useQueryClient } from "@tanstack/svelte-query";
import { onMount } from "svelte";
import { PUBLIC_STRIPE_KEY } from "$env/static/public";

interface Props {
	workshopId: string;
	workshopTitle: string;
	amount: number; // in cents
	currency?: string;
	customerId?: string;
	onSuccess?: () => void;
	onCancel?: () => void;
}

const {
	workshopId,
	workshopTitle,
	amount,
	currency = "eur",
	customerId,
	onSuccess,
	onCancel,
}: Props = $props();

const stripeElementsOptions: StripeElementsOptionsClientSecret = $derived({
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
});

let stripe: Awaited<ReturnType<typeof loadStripe>> | null = $state(null);
let elements: StripeElements | null = $state(null);
let paymentElement: StripePaymentElement | null = $state(null);
let _isLoading = $state(false);
let _error = $state<string | null>(null);
let _success = $state(false);
const paymentElementContainer: HTMLDivElement | null = $state(null);
let _currentPaymentIntentId = $state<string | null>(null);

const queryClient = useQueryClient();

// Create payment intent mutation
const createPaymentIntent = createMutation(() => ({
	mutationFn: async () => {
		const response = await fetch(
			`/api/workshops/${workshopId}/register/payment-intent`,
			{
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({
					amount,
					currency,
					...(customerId ? { customerId } : {}),
				}),
			},
		);

		if (!response.ok) {
			const errorData = (await response.json()) as { error?: string };
			throw new Error(errorData.error || "Failed to create payment intent");
		}

		return response.json() as Promise<{
			clientSecret: string;
			paymentIntentId: string;
		}>;
	},
	onSuccess: (data: { clientSecret: string; paymentIntentId: string }) => {
		initializeCheckout(data);
	},
	onError: (err) => {
		_error =
			err instanceof Error ? err.message : "Failed to initialize payment";
	},
}));

// Complete registration mutation
const completeRegistration = createMutation(() => ({
	mutationFn: async (paymentIntentId: string) => {
		const response = await fetch(
			`/api/workshops/${workshopId}/register/complete`,
			{
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({
					paymentIntentId,
				}),
			},
		);

		if (!response.ok) {
			const errorData = (await response.json()) as { error?: string };
			throw new Error(errorData.error || "Failed to complete registration");
		}

		return response.json();
	},
	onSuccess: () => {
		_success = true;
		// Invalidate workshop queries to refresh UI
		queryClient.invalidateQueries({ queryKey: ["workshops"] });
		onSuccess?.();
	},
	onError: (err) => {
		_error = err instanceof Error ? err.message : "Registration failed";
	},
}));

async function _handlePaymentConfirmation(paymentIntentId: string) {
	try {
		_isLoading = true;
		const { error: confirmError } = await stripe?.confirmPayment({
			elements: elements!,
			confirmParams: {
				return_url: `${window.location.origin}/dashboard/my-workshops`,
			},
			redirect: "if_required",
		});

		if (confirmError) {
			throw new Error(confirmError.message);
		}

		await completeRegistration.mutateAsync(paymentIntentId);
	} catch (err) {
		_error = err instanceof Error ? err.message : "Payment failed";
	} finally {
		_isLoading = false;
	}
}

async function initializeCheckout({
	clientSecret,
	paymentIntentId,
}: {
	clientSecret: string;
	paymentIntentId: string;
}) {
	if (!stripe) return;

	_currentPaymentIntentId = paymentIntentId;

	try {
		elements = stripe.elements({
			...stripeElementsOptions,
			clientSecret: clientSecret,
		});

		// Create regular Payment element for card/revolut_pay
		paymentElement = elements.create("payment", {
			layout: "tabs",
		});

		// Always show both payment methods for now
		// The Express Checkout will hide itself if no express methods are available
	} catch (err) {
		_error =
			err instanceof Error ? err.message : "Failed to initialize payment";
	}
}

// Effect to mount the Payment element
$effect(() => {
	if (paymentElement && paymentElementContainer) {
		paymentElement.mount(paymentElementContainer);

		return () => {
			if (paymentElement) {
				paymentElement.unmount();
			}
		};
	}
});

onMount(() => {
	loadStripe(PUBLIC_STRIPE_KEY).then((loadedStripe) => {
		try {
			if (!loadedStripe) {
				throw new Error("Failed to load Stripe");
			}
			stripe = loadedStripe;
			// Create payment intent when component mounts
			createPaymentIntent.mutate();
		} catch (err) {
			_error =
				err instanceof Error ? err.message : "Failed to initialize Stripe";
		}
	});
});
</script>

{#if success}
	<Alert.Root variant="success" class="w-full">
		<Alert.Title>Registration Successful!</Alert.Title>
		<Alert.Description>
			You have successfully registered for {workshopTitle}. You will receive a confirmation email
			shortly.
		</Alert.Description>
	</Alert.Root>
{:else if error}
	<Alert.Root variant="destructive" class="w-full mb-4">
		<Alert.Title>Registration Failed</Alert.Title>
		<Alert.Description>{error}</Alert.Description>
		<div class="mt-2 flex gap-2">
			<Button
				variant="outline"
				size="sm"
				onclick={() => {
					error = null;
					createPaymentIntent.mutate();
				}}
			>
				Try Again
			</Button>
			{#if onCancel}
				<Button variant="ghost" size="sm" onclick={onCancel}>Cancel</Button>
			{/if}
		</div>
	</Alert.Root>
{:else}
	<div class="max-h-[80vh] overflow-y-auto">
		<div class="space-y-4 p-1">
			<div class="text-center">
				<h3 class="text-lg font-semibold">Register for {workshopTitle}</h3>
				<p class="text-sm text-muted-foreground">
					Amount: €{(amount / 100).toFixed(2)}
				</p>
			</div>

			{#if createPaymentIntent.isPending}
				<div class="flex items-center justify-center py-8">
					<LoaderCircle />
					<span class="ml-2">Initializing payment...</span>
				</div>
			{:else}
				<div class="space-y-4">
					{#if isLoading}
						<div class="flex items-center justify-center py-4">
							<LoaderCircle />
							<span class="ml-2">Processing payment...</span>
						</div>
					{/if}

					<!-- Regular Payment Element (Card, Revolut Pay) -->
					<div bind:this={paymentElementContainer} class="min-h-[200px]"></div>
					<Button
						onclick={() => handlePaymentConfirmation(currentPaymentIntentId!)}
						disabled={isLoading || !currentPaymentIntentId}
						class="w-full"
					>
						{#if isLoading}
							<LoaderCircle class="mr-2 h-4 w-4" />
						{/if}
						Complete Payment
					</Button>

					<div class="text-xs text-muted-foreground text-center">
						Secure payment powered by Stripe
					</div>
				</div>
			{/if}
		</div>
	</div>
{/if}
