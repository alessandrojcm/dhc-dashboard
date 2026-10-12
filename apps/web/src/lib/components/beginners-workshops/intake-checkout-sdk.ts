import type {
	StripeEmbeddedCheckout,
	StripeEmbeddedCheckoutOptions,
} from "@stripe/stripe-js";
import { loadStripe } from "@stripe/stripe-js/pure";
import { PUBLIC_STRIPE_KEY } from "$app/env/public";

export type IntakeCheckoutWidget = Pick<
	StripeEmbeddedCheckout,
	"mount" | "destroy"
>;
export type IntakeCheckoutFactory = (
	options: StripeEmbeddedCheckoutOptions,
) => Promise<IntakeCheckoutWidget>;

export const createIntakeCheckout: IntakeCheckoutFactory = async (options) => {
	const stripe = await loadStripe(PUBLIC_STRIPE_KEY);
	if (!stripe) throw new Error("Stripe unavailable");
	return stripe.initEmbeddedCheckout(options);
};
