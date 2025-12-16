/**
 * Refund Service
 * Handles workshop refund processing and management
 */

import type { Kysely, KyselyDatabase, Logger, Session, Transaction } from '../shared';
import { executeWithRLS } from '../shared';
import { stripeClient } from '$lib/server/stripe';
import type { Refund, RefundEligibility, RefundWithUser } from './types';

// ============================================================================
// Refund Service
// ============================================================================

export class RefundService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		logger?: Logger
	) {
		this.logger = logger ?? console;
	}

	// ========================================================================
	// Query Methods
	// ========================================================================

	/**
	 * Get all refunds for a workshop
	 */
	async getWorkshopRefunds(workshopId: string): Promise<RefundWithUser[]> {
		this.logger.info('Fetching workshop refunds', { workshopId });

		return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
			const refunds = await trx
				.selectFrom('club_activity_refunds as car')
				.innerJoin('club_activity_registrations as reg', 'car.registration_id', 'reg.id')
				.leftJoin('user_profiles as up', 'reg.member_user_id', 'up.supabase_user_id')
				.leftJoin('external_users as eu', 'reg.external_user_id', 'eu.id')
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
					'car.updated_at',
					'car.stripe_payment_intent_id',
					'up.first_name as member_first_name',
					'up.last_name as member_last_name',
					'eu.first_name as external_first_name',
					'eu.last_name as external_last_name',
					'eu.email as external_email'
				])
				.where('reg.club_activity_id', '=', workshopId)
				.orderBy('car.requested_at', 'desc')
				.execute();

			// Transform to include user profile data
			return refunds.map((refund) => ({
				id: refund.id,
				registration_id: refund.registration_id,
				refund_amount: refund.refund_amount,
				refund_reason: refund.refund_reason,
				status: refund.status,
				stripe_refund_id: refund.stripe_refund_id,
				requested_at: refund.requested_at,
				processed_at: refund.processed_at,
				completed_at: refund.completed_at,
				requested_by: refund.requested_by,
				processed_by: refund.processed_by,
				created_at: refund.created_at,
				updated_at: refund.updated_at,
				stripe_payment_intent_id: refund.stripe_payment_intent_id,
				user_profiles: refund.member_first_name
					? {
							first_name: refund.member_first_name,
							last_name: refund.member_last_name!
						}
					: null,
				external_users: refund.external_first_name
					? {
							first_name: refund.external_first_name,
							last_name: refund.external_last_name!,
							email: refund.external_email!
						}
					: null
			} satisfies RefundWithUser));
		});
	}

	/**
	 * Check if a registration is eligible for refund
	 */
	async checkEligibility(registrationId: string): Promise<RefundEligibility> {
		this.logger.info('Checking refund eligibility', { registrationId });

		const result = await this.kysely
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

		if (!result) {
			return {
				eligible: false,
				reason: 'Registration not found'
			};
		}

		// Check if already refunded
		if (result.registration_status === 'refunded') {
			return {
				eligible: false,
				reason: 'Registration already refunded'
			};
		}

		// Check if workshop is finished
		if (result.workshop_status === 'finished') {
			return {
				eligible: false,
				reason: 'Cannot refund finished workshop'
			};
		}

		// Check refund deadline
		if (result.refund_days !== null) {
			const refundDeadline = new Date(result.start_date);
			refundDeadline.setDate(refundDeadline.getDate() - result.refund_days);

			if (new Date() > refundDeadline) {
				return {
					eligible: false,
					reason: 'Refund deadline has passed'
				};
			}
		}

		// Check if refund already exists
		const existingRefund = await this.kysely
			.selectFrom('club_activity_refunds')
			.select('id')
			.where('registration_id', '=', registrationId)
			.executeTakeFirst();

		if (existingRefund) {
			return {
				eligible: false,
				reason: 'Refund already requested for this registration'
			};
		}

		return {
			eligible: true,
			registration: {
				id: result.id,
				amount_paid: result.amount_paid,
				stripe_checkout_session_id: result.stripe_checkout_session_id,
				status: result.registration_status
			},
			workshop: {
				start_date: result.start_date,
				refund_days: result.refund_days,
				status: result.workshop_status!
			}
		};
	}

	// ========================================================================
	// Mutation Methods
	// ========================================================================

	/**
	 * Process a refund for a registration
	 * This will:
	 * 1. Check eligibility
	 * 2. Create refund record
	 * 3. Update registration status
	 * 4. Process Stripe refund if applicable
	 */
	async processRefund(registrationId: string, reason: string): Promise<Refund> {
		this.logger.info('Processing refund', { registrationId, reason });

		// Use kysely transaction directly (not executeWithRLS) since we need
		// to handle Stripe API calls within the transaction
		return await this.kysely.transaction().execute(async (trx) => {
			return this._processRefund(trx, registrationId, reason);
		});
	}

	// ========================================================================
	// Private Transactional Methods (for cross-service coordination)
	// ========================================================================

	/**
	 * Internal transactional method for processing refund
	 */
	async _processRefund(
		trx: Transaction<KyselyDatabase>,
		registrationId: string,
		reason: string
	): Promise<Refund> {
		// Check eligibility
		const eligibility = await this.checkEligibility(registrationId);

		if (!eligibility.eligible) {
			throw new Error(eligibility.reason || 'Refund not eligible', {
				cause: {
					registrationId,
					context: 'RefundService._processRefund'
				}
			});
		}

		// Create refund record
		const refund = await trx
			.insertInto('club_activity_refunds')
			.values({
				registration_id: registrationId,
				refund_amount: eligibility.registration!.amount_paid,
				refund_reason: reason,
				status: 'pending',
				requested_by: this.session.user.id
			})
			.returningAll()
			.executeTakeFirstOrThrow();

		// Update registration status
		await trx
			.updateTable('club_activity_registrations')
			.set({ status: 'refunded' })
			.where('id', '=', registrationId)
			.execute();

		// Process Stripe refund if applicable
		if (eligibility.registration!.stripe_checkout_session_id) {
			try {
				// Get the payment intent from the checkout session
				const paymentIntent = await stripeClient.paymentIntents.retrieve(
					eligibility.registration!.stripe_checkout_session_id
				);

				if (!paymentIntent) {
					throw new Error('No payment intent found for checkout session');
				}

				// Create the refund
				const stripeRefund = await stripeClient.refunds.create({
					payment_intent: paymentIntent.id,
					amount: eligibility.registration!.amount_paid,
					reason: 'requested_by_customer'
				});

				// Update refund record with Stripe info
				await trx
					.updateTable('club_activity_refunds')
					.set({
						stripe_refund_id: stripeRefund.id,
						status: 'processing',
						processed_at: new Date().toISOString(),
						processed_by: this.session.user.id
					})
					.where('id', '=', refund.id)
					.execute();
			} catch (stripeError) {
				// Mark refund as failed
				await trx
					.updateTable('club_activity_refunds')
					.set({ status: 'failed' })
					.where('id', '=', refund.id)
					.execute();
				throw stripeError;
			}
		}

		return refund;
	}
}
