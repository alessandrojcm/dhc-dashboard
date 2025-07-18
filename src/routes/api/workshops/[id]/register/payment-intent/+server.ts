import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import { stripeClient } from '$lib/server/stripe';
import * as Sentry from '@sentry/sveltekit';
import * as v from 'valibot';

const paymentIntentSchema = v.object({
	amount: v.number(),
	currency: v.optional(v.string(), 'eur'),
	customerId: v.optional(v.string())
});

export const POST: RequestHandler = async ({ request, params, locals, platform }) => {
	try {
		const { id: workshopId } = params;
		const body = await request.json();

		const validatedData = v.safeParse(paymentIntentSchema, body);
		if (!validatedData.success) {
			return json({ success: false, error: 'Invalid request data' }, { status: 400 });
		}

		const { amount, currency, customerId } = validatedData.output;

		const { session } = await locals.safeGetSession();
		if (!session?.user) {
			return json({ success: false, error: 'Authentication required' }, { status: 401 });
		}

		const kysely = getKyselyClient(platform!.env.HYPERDRIVE!);

		// Get workshop details and verify it exists
		const workshop = await executeWithRLS(kysely, { claims: session }, async (trx) =>
			trx
				.selectFrom('club_activities')
				.select(['id', 'title', 'status', 'price_member', 'price_non_member', 'max_capacity'])
				.where('id', '=', workshopId)
				.executeTakeFirst()
		);

		if (!workshop) {
			return json({ success: false, error: 'Workshop not found' }, { status: 404 });
		}

		if (workshop.status !== 'published') {
			return json(
				{ success: false, error: 'Workshop is not available for registration' },
				{ status: 400 }
			);
		}

		// Check if user is already registered
		const existingRegistration = await executeWithRLS(kysely, { claims: session }, async (trx) =>
			trx
				.selectFrom('club_activity_registrations')
				.select(['id', 'status'])
				.where('club_activity_id', '=', workshopId)
				.where('member_user_id', '=', session.user.id)
				.where('status', 'in', ['pending', 'confirmed'])
				.executeTakeFirst()
		);

		if (existingRegistration) {
			return json(
				{ success: false, error: 'You are already registered for this workshop' },
				{ status: 409 }
			);
		}

		// Check capacity
		const registrationCount = await executeWithRLS(kysely, { claims: session }, async (trx) =>
			trx
				.selectFrom('club_activity_registrations')
				.select(trx.fn.count('id').as('count'))
				.where('club_activity_id', '=', workshopId)
				.where('status', 'in', ['pending', 'confirmed'])
				.executeTakeFirst()
		);

		if (Number(registrationCount?.count) >= workshop.max_capacity) {
			return json({ success: false, error: 'Workshop is at full capacity' }, { status: 409 });
		}

		// Create Stripe payment intent
		const paymentIntentData: Parameters<typeof stripeClient.paymentIntents.create>[0] = {
			amount,
			currency,
			metadata: {
				workshop_id: workshopId,
				workshop_title: workshop.title,
				user_id: session.user.id,
				type: 'workshop_registration'
			},
			automatic_payment_methods: {
				enabled: false
			},
			payment_method_types: ['card', 'link', 'revolut_pay']
		};

		// Attach customer if provided
		if (customerId) {
			paymentIntentData.customer = customerId;
		}

		const paymentIntent = await stripeClient.paymentIntents.create(paymentIntentData);

		return json({
			success: true,
			clientSecret: paymentIntent.client_secret,
			paymentIntentId: paymentIntent.id
		});
	} catch (error) {
		Sentry.captureException(error);
		console.error('Payment intent creation error:', error);

		return json(
			{
				success: false,
				error: 'Failed to create payment intent'
			},
			{ status: 500 }
		);
	}
};
