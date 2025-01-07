// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import Stripe from 'npm:stripe@17.5.0';
import dayjs from 'npm:dayjs';
import { db } from '../_shared/db.ts';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
	apiVersion: '2024-12-18.acacia',
	maxNetworkRetries: 3,
    timeout: 30 * 1000
});

const corsHeaders = {
	'Access-Control-Allow-Origin': '*',
	'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};

async function setLastPayment(customerId: string, paidDate: number, subscriptionEnd: number) {
  await db
    .updateTable('member_profiles')
    .set({ 
      last_payment_date: dayjs.unix(paidDate).toDate(), 
      membership_end_date: dayjs.unix(subscriptionEnd).toDate() 
    })
    .whereExists(
      qb => qb.selectFrom('user_profiles')
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

addEventListener('beforeUnload', (ev) => {
	console.log('task terminated because', ev);
});

Deno.serve(async (req) => {
	if (req.method === 'OPTIONS') {
		return new Response('ok', { headers: corsHeaders });
	}

	try {
		// Get the stripe signature from the headers
		const signature = req.headers.get('stripe-signature');
		if (!signature) {
			throw new Error('No stripe signature found');
		}

		// Get the raw body
		const body = await req.text();

		// Verify the webhook signature
		const event = await stripe.webhooks.constructEventAsync(
			body,
			signature,
			Deno.env.get('STRIPE_WEBHOOK_SIGNING_SECRET') ?? ''
		);

		// Handle the event
		if (event.type === 'invoice.paid') {
			const invoice = event.data.object;

			// Get the customer ID from the invoice
			const customerId = invoice.customer as string;
			
			// Get the line items to see what was paid for
			const lineItems = invoice.lines.data;
			
			// Check each line item's price lookup key to determine what was paid for
			for (const item of lineItems) {
				const lookupKey = item.price.lookup_key;
				
				if (lookupKey === 'standard_membership_fee') {
					console.log(`Customer ${customerId} paid for standard membership fee`);
					EdgeRuntime.waitUntil(setLastPayment(customerId, invoice.created, invoice.period_end));
				} else if (lookupKey === 'annual_membership_fee') {
					console.log(`Customer ${customerId} paid for annual membership fee`);
				}
			}

			return new Response(JSON.stringify({ success: true }), {
				headers: { ...corsHeaders, 'Content-Type': 'application/json' },
				status: 200
			});
		} else if (event.type === 'customer.subscription.deleted') {
			const subscription = event.data.object;
			const customerId = subscription.customer as string;

			// Get the subscription items to check what was cancelled
			const items = subscription.items.data;
			for (const item of items) {
				const lookupKey = item.price.lookup_key;
				if (lookupKey === 'standard_membership_fee') {
					console.log(`Standard membership cancelled for customer ${customerId}`);
					EdgeRuntime.waitUntil(setUserInactive(customerId));
					break;
				}
			}

			return new Response(JSON.stringify({ success: true }), {
				headers: { ...corsHeaders, 'Content-Type': 'application/json' },
				status: 200
			});
		}

		// Return a 200 for other events we're not handling
		return new Response(JSON.stringify({ received: true }), {
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
