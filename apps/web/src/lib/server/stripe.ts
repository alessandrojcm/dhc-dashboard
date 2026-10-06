import stripe from "stripe";
import { STRIPE_SECRET_KEY } from "$app/env/private";

export const stripeClient = new stripe(STRIPE_SECRET_KEY!, {
	apiVersion: "2025-10-29.clover",
});
