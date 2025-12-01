// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

import { Stripe } from 'stripe';
import dayjs from 'npm:dayjs';
import { db } from '../_shared/db.ts';
import { corsHeaders } from '../_shared/cors.ts';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') ?? '', {
	apiVersion: '2025-09-30.clover',
	maxNetworkRetries: 3,
	timeout: 30 * 1000,
	httpClient: Stripe.createFetchHttpClient()
});

const allowedEvents: Stripe.Event.Type[] = [
	'charge.succeeded',
	'charge.expired',
	'charge.refunded',
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

async function setUserInactive(customerId: string) {
	await db
		.updateTable('user_profiles')
		.set({ is_active: false })
		.where('customer_id', '=', customerId)
		.execute()
		.then(console.log);
}

async function handleWorkshopCheckoutCompleted(session: Stripe.Charge) {
	try {
		if (session.metadata?.workshop_id && session.metadata?.registration_data) {
			const registrationData = JSON.parse(session.metadata.registration_data);

			// Create the registration record now that payment is complete
			await db
				.selectFrom(
					db
						.fn('register_for_workshop_checkout', [
							session.metadata.workshop_id,
							session.amount || 0,
							session.id,
							registrationData.memberUserId || null,
							registrationData.externalUserData
								? JSON.stringify(registrationData.externalUserData)
								: null
						])
						.as('registration_id')
				)
				.select('registration_id')
				.executeTakeFirst();

			// Update status to confirmed since payment is complete
			await db
				.updateTable('club_activity_registrations')
				.set({
					status: 'confirmed',
					confirmed_at: new Date()
				})
				.where('stripe_checkout_session_id', '=', session.id)
				.execute();

			console.log(`Workshop registration confirmed for checkout session: ${session.id}`);
		}
	} catch (error) {
		console.error('Error handling workshop checkout completion:', error);
		throw error;
	}
}

async function handleWorkshopCheckoutExpired(session: Stripe.Charge) {
	try {
		if (session.metadata?.workshop_id) {
			// Mark any pending registrations as cancelled
			await db
				.updateTable('club_activity_registrations')
				.set({
					status: 'cancelled',
					cancelled_at: new Date()
				})
				.where('stripe_checkout_session_id', '=', session.id)
				.where('status', '=', 'pending')
				.execute();

			console.log(`Workshop registration cancelled for expired checkout session: ${session.id}`);
		}
	} catch (error) {
		console.error('Error handling workshop checkout expiration:', error);
		throw error;
	}
}

async function handleChargeRefunded(charge: Stripe.Charge) {
	try {
		// Get all refunds for this charge
		const refunds = await stripe.refunds.list({
			charge: charge.id,
			limit: 100
		});

		for (const refund of refunds.data) {
			// Update refund status based on Stripe refund status
			let status: 'completed' | 'failed' | 'processing';
			let completed_at: Date | null = null;

			switch (refund.status) {
				case 'succeeded':
					status = 'completed';
					completed_at = new Date();
					break;
				case 'failed':
					status = 'failed';
					break;
				case 'pending':
				case 'requires_action':
					status = 'processing';
					break;
				default:
					status = 'processing';
			}

			// Update refund status in database
			const updateData: { status: string; completed_at?: string } = { status };
			if (completed_at) {
				updateData.completed_at = completed_at;
			}

			await db
				.updateTable('club_activity_refunds')
				.set(updateData)
				.where('stripe_refund_id', '=', refund.id)
				.execute();

			console.log(`Refund status updated: ${refund.id} -> ${status} for charge: ${charge.id}`);
		}
	} catch (error) {
		console.error('Error handling charge refund:', error);
		throw error;
	}
}

async function syncStripeDataToKV(customerId: string) {
	try {
		// Fetch latest subscription data from Stripe
		const subscriptions = await stripe.subscriptions.list({
			customer: customerId,
			limit: 2, // User can have at most 2 subscriptions
			status: 'all',
			expand: ['data.latest_invoice']
		});

		// Find the standard membership subscription
		const standardMembershipSub = subscriptions.data.find((sub) =>
			sub.items.data.some((item) => item.price.lookup_key === 'standard_membership_fee')
		);

		// If no standard membership or it's canceled/expired/unpaid, mark user as inactive
		if (
			!standardMembershipSub ||
			['canceled', 'incomplete_expired', 'unpaid'].includes(standardMembershipSub.status)
		) {
			return setUserInactive(customerId);
		}

		// Handle paused subscriptions - keep user active, update pause status in DB
		if (standardMembershipSub.pause_collection !== null) {
			const resumeDate = standardMembershipSub.pause_collection?.resumes_at
				? dayjs.unix(standardMembershipSub.pause_collection.resumes_at).toDate()
				: null;

			// Update pause status in database
			await db
				.updateTable('member_profiles')
				.set({ subscription_paused_until: resumeDate })
				.where(
					'user_profile_id',
					'in',
					db.selectFrom('user_profiles').select('id').where('customer_id', '=', customerId)
				)
				.execute();

			console.log(`Subscription paused for customer: ${customerId} until ${resumeDate}`);
			return Promise.resolve();
		}

		if (standardMembershipSub.status === 'active') {
			await db.transaction().execute((trx) => {
				return Promise.all([
					trx
						.updateTable('member_profiles')
						.set({
							subscription_paused_until: null,
							last_payment_date: dayjs.unix(standardMembershipSub.start_date).toDate(),
							membership_end_date: standardMembershipSub.ended_at
								? dayjs.unix(standardMembershipSub.ended_at).toDate()
								: null
						})
						.where(
							'user_profile_id',
							'in',
							db.selectFrom('user_profiles').select('id').where('customer_id', '=', customerId)
						)
						.execute(),
					trx
						.updateTable('user_profiles')
						.set({ is_active: true })
						.where('customer_id', '=', customerId)
						.execute()
				]);
			});
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

		// Handle workshop registration checkout sessions
		if (event.type === 'charge.succeeded') {
			const session = event.data.object as Stripe.Charge;
			if (session.metadata?.workshop_id) {
				EdgeRuntime.waitUntil(handleWorkshopCheckoutCompleted(session));
			}
		} else if (event.type === 'charge.expired') {
			const session = event.data.object as Stripe.Charge;
			if (session.metadata?.workshop_id) {
				EdgeRuntime.waitUntil(handleWorkshopCheckoutExpired(session));
			}
		} else if (event.type === 'charge.refunded') {
			const charge = event.data.object as Stripe.Charge;
			EdgeRuntime.waitUntil(handleChargeRefunded(charge));
		}

		// Handle subscription-related events
		const eventObject = event?.data?.object as { customer?: string };
		if (eventObject.customer) {
			// Sync stripe data for subscription events
			EdgeRuntime.waitUntil(syncStripeDataToKV(eventObject.customer));
		}

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
