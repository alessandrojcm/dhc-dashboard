import { json, error } from '@sveltejs/kit';
import { getKyselyClient, executeWithRLS } from '$lib/server/kysely';
import { stripeClient } from '$lib/server/stripe';
import { moveCancelledAttendeeToWaitlist } from '$lib/server/kyselyRPCFunctions';
import type { RequestHandler } from './$types';
import * as v from 'valibot';
import * as Sentry from '@sentry/sveltekit';
import { getRolesFromSession } from '$lib/server/roles';

const refundAttendeeSchema = v.object({
	reason: v.optional(v.string()),
	moveToWaitlist: v.optional(v.boolean(), false)
});

export const POST: RequestHandler = async ({ params, request, locals, platform }) => {
	// Check authentication
	const { session } = await locals.safeGetSession();
	if (!session) throw error(401, 'Not authenticated');

	// Role check - same roles allowed for workshop management
	const roles = getRolesFromSession(session) as Set<string>;
	const allowed = new Set(['admin', 'president', 'beginners_coordinator']);
	const intersection = new Set([...roles].filter((role) => allowed.has(role)));
	if (intersection.size === 0) {
		throw error(403, 'Insufficient permissions');
	}

	const workshopId = params.id;
	const attendeeId = params.attendeeId;

	if (!workshopId || !attendeeId) {
		throw error(400, 'Workshop ID and Attendee ID required');
	}

	const db = getKyselyClient(platform?.env.HYPERDRIVE);
	if (!db) {
		throw error(500, 'Database connection failed');
	}

	let body: unknown;
	try {
		body = await request.json();
	} catch (err) {
		Sentry.captureException(err);
		throw error(400, 'Invalid JSON');
	}

	const parsed = v.safeParse(refundAttendeeSchema, body);
	if (!parsed.success) {
		Sentry.captureException(parsed.issues);
		throw error(400, 'Validation failed: ' + JSON.stringify(parsed.issues));
	}
	const { reason, moveToWaitlist } = parsed.output;

	try {
		const result = await executeWithRLS(db, { claims: session }, async (trx) => {
			// First, verify the attendee exists and get their payment details
			const attendee = await trx
				.selectFrom('workshop_attendees')
				.leftJoin('user_profiles', 'workshop_attendees.user_profile_id', 'user_profiles.id')
				.select([
					'workshop_attendees.id',
					'workshop_attendees.status',
					'workshop_attendees.paid_at',
					'workshop_attendees.payment_url_token',
					'workshop_attendees.user_profile_id',
					'workshop_attendees.workshop_id',
					'workshop_attendees.refund_processed_at',
					'workshop_attendees.stripe_refund_id',
					'user_profiles.first_name',
					'user_profiles.last_name',
					'user_profiles.customer_id'
				])
				.where('workshop_attendees.id', '=', attendeeId)
				.where('workshop_attendees.workshop_id', '=', workshopId)
				.executeTakeFirst();

			if (!attendee) {
				throw new Error('Attendee not found');
			}

			// Check if attendee has paid
			if (!attendee.paid_at) {
				throw new Error('Attendee has not paid - no refund needed');
			}

			// Check if already refunded
			if (attendee.refund_processed_at) {
				throw new Error('Refund already processed');
			}

			// Check if customer_id exists (needed for Stripe refund)
			if (!attendee.customer_id) {
				throw new Error('Customer ID not found - cannot process refund');
			}

			// Find the payment intent for this attendee
			// We need to search for charges related to this customer for the workshop amount
			const payments = await stripeClient.paymentIntents.list({
				customer: attendee.customer_id,
				limit: 50
			});

			// Find the payment intent that matches this workshop payment
			// We'll look for payments that have the payment_link metadata or are around the paid_at date
			const workshopPayment = payments.data.find((pi) => {
				// Check if this payment intent has our payment link token
				if (pi.metadata?.payment_link_token === attendee.payment_url_token) {
					return true;
				}
				// Fallback: check if payment was made around the same time as paid_at
				const paymentDate = new Date(pi.created * 1000);
				const paidDate = new Date(attendee.paid_at!);
				const timeDiff = Math.abs(paymentDate.getTime() - paidDate.getTime());
				// Within 5 minutes of each other
				return timeDiff <= 5 * 60 * 1000;
			});

			if (!workshopPayment) {
				throw new Error('Payment intent not found for this attendee');
			}

			// Process Stripe refund
			const refund = await stripeClient.refunds.create({
				payment_intent: workshopPayment.id,
				reason: 'requested_by_customer',
				metadata: {
					workshop_id: workshopId,
					attendee_id: attendeeId,
					admin_reason: reason || 'Cancelled by admin'
				}
			});

			// Update attendee record with refund details
			await trx
				.updateTable('workshop_attendees')
				.set({
					status: 'cancelled',
					cancelled_at: new Date().toISOString(),
					cancelled_by: session.user.id,
					refund_requested: true,
					refund_processed_at: new Date().toISOString(),
					stripe_refund_id: refund.id,
					waitlist_return_requested: moveToWaitlist
				})
				.where('id', '=', attendeeId)
				.execute();

			// If moving to waitlist, use the existing database function
			if (moveToWaitlist) {
				await moveCancelledAttendeeToWaitlist(
					attendeeId,
					workshopId,
					trx,
					reason || 'Refunded and moved to waitlist'
				);
			}

			return {
				attendee,
				refund,
				moveToWaitlist,
				refundAmount: refund.amount / 100 // Convert from cents to euros
			};
		});

		return json({
			success: true,
			message: 'Refund processed successfully',
			data: result
		});
	} catch (e: any) {
		Sentry.captureException(e);

		if (e.message === 'Attendee not found') {
			throw error(404, 'Attendee not found');
		}

		if (e.message === 'Attendee has not paid - no refund needed') {
			throw error(400, 'Attendee has not paid - no refund needed');
		}

		if (e.message === 'Refund already processed') {
			throw error(400, 'Refund already processed');
		}

		if (e.message === 'Customer ID not found - cannot process refund') {
			throw error(400, 'Customer ID not found - cannot process refund');
		}

		if (e.message === 'Payment intent not found for this attendee') {
			throw error(400, 'Payment intent not found for this attendee');
		}

		// Handle Stripe errors
		if (e && typeof e === 'object' && 'type' in e && e.type === 'StripeError') {
			throw error(400, `Stripe error: ${e.message}`);
		}

		throw error(500, e?.message || 'Failed to process refund');
	}
};
