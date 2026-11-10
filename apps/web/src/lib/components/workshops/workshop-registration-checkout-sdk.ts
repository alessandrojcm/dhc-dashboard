import { loadStripe } from "@stripe/stripe-js";
import { PUBLIC_STRIPE_KEY } from "$app/env/public";
import type {
	EmbeddedCheckoutFactory,
	EmbeddedCheckoutWidget,
} from "#lib/stripe/embedded-checkout-widget.js";

/** The part of Stripe this factory uses; injected so tests need no Stripe. */
type StripeLoader = () => Promise<{
	initEmbeddedCheckout(options: {
		clientSecret?: string;
	}): Promise<EmbeddedCheckoutWidget>;
} | null>;

/**
 * A factory for Checkout Sessions that redirect to their return URL on
 * completion. The widget actor's completion callback is deliberately not
 * passed on: Stripe refuses `onComplete` for sessions that always redirect.
 */
export function redirectingEmbeddedCheckout(
	load: StripeLoader,
): EmbeddedCheckoutFactory {
	return async ({ clientSecret }) => {
		const stripe = await load();
		if (!stripe) throw new Error("Stripe unavailable");
		return stripe.initEmbeddedCheckout({ clientSecret });
	};
}

/** Public regular-Workshop registration's Stripe. */
export const createWorkshopRegistrationCheckout = redirectingEmbeddedCheckout(
	() => loadStripe(PUBLIC_STRIPE_KEY),
);
