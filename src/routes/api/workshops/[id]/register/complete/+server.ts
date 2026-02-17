import * as Sentry from '@sentry/sveltekit';
import { json } from '@sveltejs/kit';
import * as v from 'valibot';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import { stripeClient } from '$lib/server/stripe';
import type { RequestHandler } from './$types';

const completeRegistrationSchema = v.object({
	paymentIntentId: v.string()
});

export const POST: RequestHandler = async ({ request, params, locals, platform }) => {
	try {
		const { id: workshopId } = params;
		const body = await request.json();

		const validatedData = v.safeParse(completeRegistrationSchema, body);
		if (!validatedData.success) {
			return json({ success: false, error: 'Invalid request data' }, { status: 400 });
		}

		const { paymentIntentId } = validatedData.output;

		const { session } = await locals.safeGetSession();
		if (!session?.user) {
			return json({ success: false, error: 'Session required' }, { status: 401 });
		}

		if (!platform?.env?.HYPERDRIVE) {
			return json({ success: false, error: 'Platform configuration missing' }, { status: 500 });
		}

		const kysely = getKyselyClient(platform.env.HYPERDRIVE);

		// Verify payment intent was successful
		const paymentIntent = await stripeClient.paymentIntents.retrieve(paymentIntentId);

		if (paymentIntent.status !== 'succeeded') {
			return json({ success: false, error: 'Payment not completed' }, { status: 400 });
		}

		// Verify the payment intent is for this workshop and user
		if (
			paymentIntent.metadata.workshop_id !== workshopId ||
			paymentIntent.metadata.user_id !== session.user.id
		) {
			return json({ success: false, error: 'Invalid payment intent' }, { status: 400 });
		}

		// Get workshop details
		const workshop = await executeWithRLS(kysely, { claims: session }, async (trx) =>
			trx
				.selectFrom('club_activities')
				.select(['id', 'title', 'price_member', 'price_non_member', 'max_capacity'])
				.where('id', '=', workshopId)
				.executeTakeFirst()
		);

		if (!workshop) {
			return json({ success: false, error: 'Workshop not found' }, { status: 404 });
		}

		// Check if already registered (race condition protection)
		const existingRegistration = await executeWithRLS(kysely, { claims: session }, async (trx) =>
			trx
				.selectFrom('club_activity_registrations')
				.select(['id'])
				.where('club_activity_id', '=', workshopId)
				.where('member_user_id', '=', session.user.id)
				.where('status', 'in', ['pending', 'confirmed'])
				.executeTakeFirst()
		);

		if (existingRegistration) {
			return json(
				{ success: false, error: 'Already registered for this workshop' },
				{ status: 409 }
			);
		}

		// Create registration record
		const registration = await executeWithRLS(kysely, { claims: session }, async (trx) =>
			trx
				.insertInto('club_activity_registrations')
				.values({
					club_activity_id: workshopId,
					member_user_id: session.user.id,
					stripe_checkout_session_id: paymentIntentId,
					amount_paid: paymentIntent.amount,
					currency: paymentIntent.currency,
					status: 'confirmed',
					confirmed_at: new Date().toISOString(),
					registered_at: new Date().toISOString()
				})
				.returning(['id', 'status'])
				.executeTakeFirst()
		);

		return json({
			success: true,
			registration: {
				id: registration?.id,
				status: registration?.status,
				workshop_title: workshop.title
			}
		});
	} catch (error) {
		Sentry.captureException(error);
		console.error('Registration completion error:', error);

		return json(
			{
				success: false,
				error: 'Failed to complete registration'
			},
			{ status: 500 }
		);
	}
};
