// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

import { Stripe } from 'stripe';
import dayjs from 'npm:dayjs';
import { db } from '../_shared/db.ts';
import { corsHeaders } from '../_shared/cors.ts';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
	apiVersion: '2025-03-31.basil',
	maxNetworkRetries: 3,
	timeout: 30 * 1000,
	httpClient: Stripe.createFetchHttpClient()
});

const allowedEvents: Stripe.Event.Type[] = [
	'checkout.session.completed',
	'customer.subscription.created',
	'customer.subscription.updated',
	'customer.subscription.deleted',
	'customer.subscription.paused',
	'customer.subscription.resumed',
	'customer.subscription.pending_update_applied',
	'customer.subscription.pending_update_expired',
	'customer.subscription.trial_will_end',
	'invoice.paid',
	'invoice.payment_failed',
	'invoice.payment_action_required',
	'invoice.upcoming',
	'invoice.marked_uncollectible',
	'invoice.payment_succeeded',
	'payment_intent.succeeded',
	'payment_intent.payment_failed',
	'payment_intent.canceled'
];

async function setLastPayment(customerId: string, paidDate: number, subscriptionEnd: number | null) {
	await db
		.updateTable('member_profiles')
		.set({
			last_payment_date: dayjs.unix(paidDate).toDate(),
			membership_end_date: subscriptionEnd ? dayjs.unix(subscriptionEnd).toDate() : null
		})
		.whereExists((qb) =>
			qb
				.selectFrom('user_profiles')
				.select('id')
				.whereRef('user_profiles.id', '=', 'member_profiles.user_profile_id')
				.where('user_profiles.customer_id', '=', customerId)
		)
		.execute()
		.then(console.log);
}

async function setUserInactive(customerId: string) {
	await db
		.updateTable('user_profiles')
		.set({ is_active: false })
		.where('customer_id', '=', customerId)
		.execute()
		.then(console.log);
}

async function syncStripeDataToKV(customerId: string) {
	try {
		// Fetch latest subscription data from Stripe
		const subscriptions: { data: Stripe.Subscription[] } = await stripe.subscriptions.list({
			customer: customerId,
			limit: 2, // User can have at most 2 subscriptions
			status: 'all',
			expand: ['data.latest_invoice']
		});

		// Find the standard membership subscription
		const standardMembershipSub = subscriptions.data.find((sub) =>
			sub.items.data.some((item) => item.price.lookup_key === 'standard_membership_fee')
		);

		// If no standard membership or it's not active, mark user as inactive
		if (
			!standardMembershipSub ||
			['canceled', 'incomplete_expired', 'paused', 'unpaid'].includes(standardMembershipSub.status)
		) {
			return setUserInactive(customerId);
		}

		// Update last payment info if subscription is active
		if (standardMembershipSub.status === 'active') {
			return setLastPayment(
				customerId,
				standardMembershipSub.start_date,
				standardMembershipSub.ended_at ?? null
			);
		}
		return Promise.resolve();
	} catch (error) {
		console.error('Error syncing Stripe data:', error);
		throw error;
	}
}

addEventListener('beforeUnload', (ev) => {
	console.log('task terminated because', ev);
});

Deno.serve(async (req) => {
	if (req.method === 'OPTIONS') {
		return new Response('ok', { headers: corsHeaders });
	}

	try {
		const signature = req.headers.get('stripe-signature');
		if (!signature) {
			throw new Error('No stripe signature found');
		}

		const body = await req.text();
		const event = await stripe.webhooks.constructEventAsync(
			body,
			signature,
			Deno.env.get('STRIPE_WEBHOOK_SIGNING_SECRET') ?? ''
		);

		// Check if event type is in allowed events
		if (!allowedEvents.includes(event.type as Stripe.Event.Type)) {
			console.log(`Ignoring unhandled event type: ${event.type}`);
			return new Response(JSON.stringify({ received: true }), {
				headers: { ...corsHeaders, 'Content-Type': 'application/json' },
				status: 200
			});
		}

		const { customer: customerId } = event?.data?.object as {
			customer: string;
		};

		// Sync stripe data for all relevant events
		EdgeRuntime.waitUntil(syncStripeDataToKV(customerId));

		return new Response(JSON.stringify({ success: true }), {
			headers: { ...corsHeaders, 'Content-Type': 'application/json' },
			status: 200
		});
	} catch (err) {
		console.error('Error processing webhook:', err);
		return new Response(JSON.stringify({ error: (err as Error)?.message }), {
			headers: { ...corsHeaders, 'Content-Type': 'application/json' },
			status: 400
		});
	}
});

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/stripe-webhooks' \
    --header 'Stripe-Signature: YOUR_SIGNATURE' \
    --header 'Content-Type: application/json' \
    --data-raw '{
      "type": "payment_intent.succeeded",
      "data": {
        "object": {
          "id": "pi_123",
          "customer": "cus_123"
        }
      }
    }'
*/
