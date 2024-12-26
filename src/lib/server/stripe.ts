import stripe from "stripe";
import { env } from '$env/dynamic/private';

export const stripeClient = new stripe(env.STRIPE_SECRET_KEY!, {
    apiVersion: '2024-11-20.acacia',
});