import { loadStripe } from "@stripe/stripe-js/pure";
import { PUBLIC_STRIPE_KEY } from "$app/env/public";
import type { EmbeddedCheckoutFactory } from "#lib/stripe/embedded-checkout-widget.js";

/** The Intake page's Stripe: loaded on first use, never at import. */
export const createIntakeCheckout: EmbeddedCheckoutFactory = async (
	options,
) => {
	const stripe = await loadStripe(PUBLIC_STRIPE_KEY);
	if (!stripe) throw new Error("Stripe unavailable");
	return stripe.initEmbeddedCheckout(options);
};
