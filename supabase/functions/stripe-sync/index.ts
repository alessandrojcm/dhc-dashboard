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

async function setUserInactive(customerId: string) {
	await db
		.updateTable('user_profiles')
		.set({ is_active: false })
		.where('customer_id', '=', customerId)
		.execute();
}

async function syncStripeDataToKV(customerId: string) {
	try {
		const subscriptions = await stripe.subscriptions.list({
			customer: customerId,
			limit: 2,
			status: 'all',
			expand: ['data.latest_invoice']
		});

		const standardMembershipSub = subscriptions.data.find((sub) =>
			sub.items.data.some((item) => item.price.lookup_key === 'standard_membership_fee')
		);

		if (
			!standardMembershipSub ||
			['canceled', 'incomplete_expired', 'unpaid'].includes(standardMembershipSub.status)
		) {
			return setUserInactive(customerId);
		}

		if (standardMembershipSub.pause_collection !== null) {
			const resumeDate = standardMembershipSub.pause_collection?.resumes_at
				? dayjs.unix(standardMembershipSub.pause_collection.resumes_at).toDate()
				: null;

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

Deno.serve(async (req) => {
	if (req.method === 'OPTIONS') {
		return new Response('ok', { headers: corsHeaders });
	}

	try {
		const authHeader = req.headers.get('Authorization');
		const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

		if (!authHeader || !authHeader.includes(serviceRoleKey ?? '')) {
			return new Response(JSON.stringify({ error: 'Unauthorized' }), {
				status: 401,
				headers: { ...corsHeaders, 'Content-Type': 'application/json' }
			});
		}

		const { customer_id } = await req.json();

		if (!customer_id) {
			return new Response(JSON.stringify({ error: 'customer_id is required' }), {
				status: 400,
				headers: { ...corsHeaders, 'Content-Type': 'application/json' }
			});
		}

		await syncStripeDataToKV(customer_id);

		return new Response(JSON.stringify({ success: true }), {
			headers: { ...corsHeaders, 'Content-Type': 'application/json' },
			status: 200
		});
	} catch (err) {
		console.error('Error syncing customer:', err);
		return new Response(JSON.stringify({ error: (err as Error)?.message }), {
			headers: { ...corsHeaders, 'Content-Type': 'application/json' },
			status: 400
		});
	}
});
