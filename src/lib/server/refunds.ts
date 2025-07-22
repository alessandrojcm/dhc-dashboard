import { executeWithRLS, getKyselyClient } from './kysely';
import type { Session } from '@supabase/supabase-js';
import { stripeClient } from './stripe';

export async function processRefund(
	registrationId: string,
	reason: string,
	session: Session,
	platform: App.Platform
): Promise<{
	id: string;
	registration_id: string;
	refund_amount: number;
	refund_reason: string | null;
	status: string;
	stripe_refund_id: string | null;
	requested_at: string;
	processed_at: string | null;
	completed_at: string | null;
	requested_by: string | null;
	processed_by: string | null;
	created_at: string | null;
	updated_at: string | null;
}> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);

	return await executeWithRLS(kysely, { claims: session }, async (trx) => {
		// Check eligibility
		const eligibilityResult = await trx
			.selectFrom('club_activity_registrations as car')
			.innerJoin('club_activities as ca', 'car.club_activity_id', 'ca.id')
			.select([
				'car.id',
				'car.amount_paid',
				'car.stripe_checkout_session_id',
				'car.status as registration_status',
				'ca.start_date',
				'ca.refund_days',
				'ca.status as workshop_status'
			])
			.where('car.id', '=', registrationId)
			.executeTakeFirst();

		if (!eligibilityResult) {
			throw new Error('Registration not found');
		}

		// Validate refund eligibility
		if (eligibilityResult.registration_status === 'refunded') {
			throw new Error('Registration already refunded');
		}

		if (eligibilityResult.workshop_status === 'finished') {
			throw new Error('Cannot refund finished workshop');
		}

		// Check refund deadline
		if (eligibilityResult.refund_days !== null) {
			const refundDeadline = new Date(eligibilityResult.start_date);
			refundDeadline.setDate(refundDeadline.getDate() - eligibilityResult.refund_days);

			if (new Date() > refundDeadline) {
				throw new Error('Refund deadline has passed');
			}
		}

		// Check if refund already exists
		const existingRefund = await trx
			.selectFrom('club_activity_refunds')
			.select('id')
			.where('registration_id', '=', registrationId)
			.executeTakeFirst();

		if (existingRefund) {
			throw new Error('Refund already requested for this registration');
		}

		// Create refund record
		const refund = await trx
			.insertInto('club_activity_refunds')
			.values({
				registration_id: registrationId,
				refund_amount: eligibilityResult.amount_paid,
				refund_reason: reason,
				status: 'pending',
				requested_by: session.user.id
			})
			.returning([
				'id',
				'registration_id',
				'refund_amount',
				'refund_reason',
				'status',
				'stripe_refund_id',
				'requested_at',
				'processed_at',
				'completed_at',
				'requested_by',
				'processed_by',
				'created_at',
				'updated_at'
			])
			.executeTakeFirstOrThrow();

		// Update registration status
		await trx
			.updateTable('club_activity_registrations')
			.set({ status: 'refunded' })
			.where('id', '=', registrationId)
			.execute();

		// Process Stripe refund asynchronously
		if (eligibilityResult.stripe_checkout_session_id) {
			try {
				// Get the payment intent from the checkout session
				const checkoutSession = await stripeClient.checkout.sessions.retrieve(
					eligibilityResult.stripe_checkout_session_id
				);

				if (!checkoutSession.payment_intent) {
					throw new Error('No payment intent found for checkout session');
				}

				// Create the refund
				const stripeRefund = await stripeClient.refunds.create({
					payment_intent: checkoutSession.payment_intent as string,
					amount: eligibilityResult.amount_paid,
					reason: 'requested_by_customer'
				});

				await trx
					.updateTable('club_activity_refunds')
					.set({
						stripe_refund_id: stripeRefund.id,
						status: 'processing',
						processed_at: new Date().toISOString(),
						processed_by: session.user.id
					})
					.where('id', '=', refund.id)
					.execute();
			} catch (stripeError) {
				await trx
					.updateTable('club_activity_refunds')
					.set({ status: 'failed' })
					.where('id', '=', refund.id)
					.execute();
				throw stripeError;
			}
		}

		return refund;
	});
}

export async function getWorkshopRefunds(
	workshopId: string,
	session: Session,
	platform: App.Platform
): Promise<{
	id: string;
	registration_id: string;
	refund_amount: number;
	refund_reason: string | null;
	status: string;
	stripe_refund_id: string | null;
	requested_at: string;
	processed_at: string | null;
	completed_at: string | null;
	requested_by: string | null;
	processed_by: string | null;
	created_at: string | null;
	updated_at: string | null;
}[]> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);

	return await executeWithRLS(kysely, { claims: session }, async (trx) => {
		return await trx
			.selectFrom('club_activity_refunds as car')
			.innerJoin('club_activity_registrations as reg', 'car.registration_id', 'reg.id')
			.select([
				'car.id',
				'car.registration_id',
				'car.refund_amount',
				'car.refund_reason',
				'car.status',
				'car.stripe_refund_id',
				'car.requested_at',
				'car.processed_at',
				'car.completed_at',
				'car.requested_by',
				'car.processed_by',
				'car.created_at',
				'car.updated_at'
			])
			.where('reg.club_activity_id', '=', workshopId)
			.orderBy('car.requested_at', 'desc')
			.execute();
	});
}
