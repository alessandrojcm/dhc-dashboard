import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import { env } from '$env/dynamic/private';
import { stripeClient } from '$lib/server/stripe';
import { registrationSchema } from '$lib/schemas/workshop-registration';
import { safeParse } from 'valibot';
import * as Sentry from '@sentry/sveltekit';

export const POST: RequestHandler = async ({ request, params, locals, platform }) => {
	try {
		const { id: workshopId } = params;
		const body = await request.json();
		const validatedData = safeParse(registrationSchema, body);
		if (!validatedData.success) {
			return json(
				{ success: false, error: 'Invalid input data', issues: validatedData.issues },
				{ status: 400 }
			);
		}
		const { session } = await locals.safeGetSession();
		const isAuthenticated = !!session?.user;

		if (!session) {
			return json({ success: false, error: 'Session required' }, { status: 401 });
		}

		const kysely = getKyselyClient(platform!.env.HYPERDRIVE!);

		// Get workshop details for pricing
		const workshop = await executeWithRLS(kysely, { claims: session }, async (trx) =>
			trx.selectFrom('club_activities').selectAll().where('id', '=', workshopId).executeTakeFirst()
		);

		if (!workshop) {
			return json({ success: false, error: 'Workshop not found' }, { status: 404 });
		}

		// Determine pricing
		const isMember = isAuthenticated && !workshop.is_public;
		const amount = isMember ? workshop.price_member : workshop.price_non_member;

		// Prepare user data
		const memberUserId = isAuthenticated ? session.user.id : null;
		const externalUserData = !isAuthenticated
			? {
					first_name: validatedData.output.firstName,
					last_name: validatedData.output.lastName,
					email: validatedData.output.email,
					phone_number: validatedData.output.phoneNumber
				}
			: null;

		// Create Stripe checkout session
		const checkoutSession = await stripeClient.checkout.sessions.create({
			payment_method_types: ['card', 'sepa_debit'],
			line_items: [
				{
					price_data: {
						currency: 'eur',
						product_data: {
							name: workshop.title,
							description: workshop.description || 'Workshop registration'
						},
						unit_amount: amount
					},
					quantity: 1
				}
			],
			mode: 'payment',
			success_url: `${env.PUBLIC_SITE_URL}/workshops/${workshopId}/confirmation?session_id={CHECKOUT_SESSION_ID}`,
			cancel_url: `${env.PUBLIC_SITE_URL}/workshops/${workshopId}`,
			customer_email: isAuthenticated ? session.user.email : validatedData.output.email,
			metadata: {
				workshop_id: workshopId,
				user_id: session?.user?.id || 'external',
				is_member: isMember.toString(),
				registration_data: JSON.stringify({
					memberUserId,
					externalUserData
				})
			}
		});

		return json({
			success: true,
			checkout_url: checkoutSession.url,
			session_id: checkoutSession.id
		});
	} catch (error) {
		Sentry.captureException(error);
		console.error('Registration error:', error);

		if (error instanceof Error && error.message?.includes('capacity')) {
			return json({ success: false, error: 'Workshop is at full capacity' }, { status: 409 });
		}

		return json({ success: false, error: 'Registration failed' }, { status: 500 });
	}
};

export const DELETE: RequestHandler = async ({ params, locals, platform }) => {
	try {
		const { id: workshopId } = params;
		const { session } = await locals.safeGetSession();

		if (!session?.user) {
			return json({ success: false, error: 'Authentication required' }, { status: 401 });
		}

		const kysely = getKyselyClient(platform!.env.HYPERDRIVE!);

		// Find and cancel registration
		const registration = await executeWithRLS(kysely, { claims: session }, async (trx) =>
			trx
				.updateTable('club_activity_registrations')
				.set({
					status: 'cancelled',
					cancelled_at: new Date().toISOString(),
					updated_at: new Date().toISOString()
				})
				.where('club_activity_id', '=', workshopId)
				.where('member_user_id', '=', session.user.id)
				.where('status', 'in', ['pending', 'confirmed'])
				.returning(['id', 'stripe_checkout_session_id'])
				.executeTakeFirst()
		);

		if (!registration) {
			return json({ success: false, error: 'Registration not found' }, { status: 404 });
		}

		// Note: With checkout sessions, we can't cancel them once created
		// The cancellation will be handled by the webhook when the session expires

		return json({
			success: true,
			registration: { id: registration.id, status: 'cancelled' }
		});
	} catch (error) {
		Sentry.captureException(error);
		return json({ success: false, error: 'Cancellation failed' }, { status: 500 });
	}
};
