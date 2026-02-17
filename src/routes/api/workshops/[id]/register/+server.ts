import * as Sentry from '@sentry/sveltekit';
import { json } from '@sveltejs/kit';
import { safeParse } from 'valibot';
import { registrationSchema } from '$lib/schemas/workshop-registration';
import { getKyselyClient } from '$lib/server/kysely';
import { stripeClient } from '$lib/server/stripe';
import { checkRefundEligibility } from '$lib/utils/refund-eligibility';
import type { RequestHandler } from './$types';
import { invariant } from '$lib/server/invariant';

export const POST: RequestHandler = async ({ request, params, platform, locals }) => {
	try {
		const { id: workshopId } = params;
		const body = await request.json();
		const validatedData = safeParse(registrationSchema, body);
		if (!validatedData.success) {
			return json({ success: false, error: 'Session required' }, { status: 401 });
		}

		if (!platform?.env?.HYPERDRIVE) {
			return json({ success: false, error: 'Platform configuration missing' }, { status: 500 });
		}
		const { session } = await locals.safeGetSession();
		invariant(Boolean(session?.user), 'Unauthorized');

		const kysely = getKyselyClient(platform.env.HYPERDRIVE);
		// Handle everything in a single transaction (using superuser permissions to bypass RLS)
		const result = await kysely.transaction().execute(async (trx) => {
			// Get registration and workshop details
			const registrationData = (await trx
				.selectFrom('club_activity_registrations as car')
				.innerJoin('club_activities as ca', 'car.club_activity_id', 'ca.id')
				.select([
					'car.id',
					'car.status as registration_status',
					'car.stripe_checkout_session_id',
					'car.amount_paid',
					'ca.start_date',
					'ca.refund_days',
					'ca.status as workshop_status'
				])
				.where('car.club_activity_id', '=', workshopId)
				.where('car.member_user_id', '=', session!.user.id)
				.where('car.status', 'in', ['pending', 'confirmed'])
				.executeTakeFirst()) as
				| {
						id: string;
						registration_status: string;
						stripe_checkout_session_id: string | null;
						amount_paid: number;
						start_date: string;
						refund_days: number | null;
						workshop_status: string;
				  }
				| undefined;

			if (!registrationData) {
				throw new Error('Registration not found');
			}

			// Check refund eligibility
			const refundEligibility = checkRefundEligibility(
				registrationData.start_date,
				registrationData.refund_days,
				registrationData.workshop_status,
				registrationData.registration_status
			);

			let refundData = null;
			let finalStatus: 'cancelled' | 'refunded' = 'cancelled';

			if (refundEligibility.isEligible) {
				// Process refund within the same transaction
				finalStatus = 'refunded';

				// Check if refund already exists
				const existingRefund = await trx
					.selectFrom('club_activity_refunds')
					.select('id')
					.where('registration_id', '=', registrationData.id)
					.executeTakeFirst();

				if (existingRefund) {
					throw new Error('Refund already requested for this registration');
				}

				const refund = await trx
					.insertInto('club_activity_refunds')
					.values({
						registration_id: registrationData.id,
						refund_amount: registrationData.amount_paid,
						refund_reason: 'Requested by attendee',
						status: 'pending',
						requested_by: session!.user.id
					})
					.returningAll()
					.executeTakeFirstOrThrow();

				// Process Stripe refund if there's a checkout session
				if (registrationData.stripe_checkout_session_id) {
					try {
						// Get the payment intent from the checkout session
						const paymentIntent = await stripeClient.paymentIntents.retrieve(
							registrationData.stripe_checkout_session_id
						);

						if (!paymentIntent) {
							throw new Error('No payment intent found for checkout session');
						}

						// Create the refund
						const stripeRefund = await stripeClient.refunds.create({
							payment_intent: paymentIntent.id,
							amount: registrationData.amount_paid,
							reason: 'requested_by_customer'
						});

						// Update refund record with Stripe details
						await trx
							.updateTable('club_activity_refunds')
							.set({
								stripe_refund_id: stripeRefund.id,
								status: 'processing',
								processed_at: new Date().toISOString(),
								processed_by: session!.user.id
							})
							.where('id', '=', refund.id)
							.execute();

						refundData = {
							...refund,
							stripe_refund_id: stripeRefund.id,
							status: 'processing'
						};
					} catch (stripeError) {
						// Mark refund as failed but don't throw - we'll still cancel the registration
						await trx
							.updateTable('club_activity_refunds')
							.set({ status: 'failed' })
							.where('id', '=', refund.id)
							.execute();

						console.error('Stripe refund failed:', stripeError);
						Sentry.captureException(stripeError);
						refundData = { ...refund, status: 'failed' };
						// Continue with cancellation even if Stripe refund fails
					}
				} else {
					refundData = refund;
				}
			}

			// Update registration status (either cancelled or refunded)
			const updatedRegistration = await trx
				.updateTable('club_activity_registrations')
				.set({
					status: finalStatus,
					cancelled_at: new Date().toISOString(),
					updated_at: new Date().toISOString()
				})
				.where('id', '=', registrationData.id)
				.returning(['id'])
				.executeTakeFirst();

			return {
				registration: { id: updatedRegistration?.id, status: finalStatus },
				refund: refundData
			};
		});

		const response: {
			success: boolean;
			registration?: typeof result.registration;
			refund?: typeof result.refund;
		} = {
			success: true,
			registration: result.registration
		};

		if (result.refund) {
			response.refund = result.refund;
		}

		return json(response);
	} catch (error) {
		Sentry.captureException(error);
		console.error('Registration cancellation error:', error);

		const errorMessage = error instanceof Error ? error.message : 'Cancellation failed';
		return json({ success: false, error: errorMessage }, { status: 500 });
	}
};
