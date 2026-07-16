/**
 * Workshop Service
 * Handles workshop CRUD operations and business logic
 */

import type { Stripe } from "stripe";
import {
	BaseWorkshopSchema,
	CreateWorkshopSchema,
	UpdateWorkshopSchema,
	type CreateWorkshopInput,
	type UpdateWorkshopInput,
} from "$lib/schemas/workshop";
import type {
	Kysely,
	KyselyDatabase,
	Logger,
	Session,
	Transaction,
} from "../shared";
import { executeWithRLS } from "../shared";
import type {
	Workshop,
	WorkshopFilters,
	WorkshopInsert,
	WorkshopUpdate,
} from "./types";

// Compatibility exports for tests and any remaining migration-only consumers.
export { BaseWorkshopSchema, CreateWorkshopSchema, UpdateWorkshopSchema };
export type { CreateWorkshopInput, UpdateWorkshopInput };

// ============================================================================
// Workshop Service
// ============================================================================

export class WorkshopService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		private stripeClient: Stripe,
		logger?: Logger,
	) {
		this.logger = logger ?? console;
	}

	// ========================================================================
	// Query Methods
	// ========================================================================

	/**
	 * Find workshop by ID
	 */
	async findById(id: string): Promise<Workshop> {
		this.logger.info("Fetching workshop by ID", { workshopId: id });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				return this._findById(trx, id);
			},
		);
	}

	/**
	 * Find multiple workshops with optional filters
	 */
	async findMany(filters?: WorkshopFilters): Promise<Workshop[]> {
		this.logger.info("Fetching workshops", { filters });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				let query = trx.selectFrom("club_activities").selectAll();

				if (filters?.status) {
					query = query.where("status", "=", filters.status);
				}
				if (filters?.startDateFrom) {
					query = query.where(
						"start_date",
						">=",
						filters.startDateFrom.toISOString(),
					);
				}
				if (filters?.startDateTo) {
					query = query.where(
						"start_date",
						"<=",
						filters.startDateTo.toISOString(),
					);
				}
				if (filters?.createdBy) {
					query = query.where("created_by", "=", filters.createdBy);
				}
				if (filters?.isPublic !== undefined) {
					query = query.where("is_public", "=", filters.isPublic);
				}

				return query.execute();
			},
		);
	}

	// ========================================================================
	// Mutation Methods
	// ========================================================================

	/**
	 * Create a new workshop
	 */
	async create(input: WorkshopInsert): Promise<Workshop> {
		this.logger.info("Creating workshop", { title: input.title });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				return this._create(trx, input);
			},
		);
	}

	/**
	 * Update an existing workshop
	 */
	async update(id: string, input: WorkshopUpdate): Promise<Workshop> {
		this.logger.info("Updating workshop", { workshopId: id });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				return this._update(trx, id, input);
			},
		);
	}

	/**
	 * Delete a workshop (only if status is 'planned')
	 */
	async delete(id: string): Promise<void> {
		this.logger.info("Deleting workshop", { workshopId: id });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				await trx
					.deleteFrom("club_activities")
					.where("id", "=", id)
					.where("status", "=", "planned")
					.execute();
			},
		);
	}

	// ========================================================================
	// Business Operations
	// ========================================================================

	/**
	 * Publish a workshop (change status from 'planned' to 'published')
	 */
	async publish(id: string): Promise<Workshop> {
		this.logger.info("Publishing workshop", { workshopId: id });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				return await trx
					.updateTable("club_activities")
					.set({ status: "published" })
					.where("id", "=", id)
					.where("status", "=", "planned")
					.returningAll()
					.executeTakeFirstOrThrow();
			},
		);
	}

	/**
	 * Cancel a workshop and process refunds for all registrations
	 */
	async cancel(id: string): Promise<Workshop> {
		this.logger.info("Cancelling workshop", { workshopId: id });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				// Get all registrations with payment info
				const registrations = await trx
					.selectFrom("club_activity_registrations")
					.select(["stripe_checkout_session_id", "amount_paid"])
					.where("club_activity_id", "=", id)
					.where("stripe_checkout_session_id", "is not", null)
					.execute();

				// Process refunds for all paid registrations
				await Promise.all(
					registrations.map(async (registration) => {
						const paymentIntent =
							await this.stripeClient.paymentIntents.retrieve(
								registration.stripe_checkout_session_id!,
							);
						if (!paymentIntent) {
							return Promise.resolve();
						}
						return this.stripeClient.refunds
							.create({
								payment_intent: paymentIntent.id,
								amount: registration.amount_paid,
								reason: "requested_by_customer",
							})
							.catch((err: Stripe.StripeRawError) => {
								if (err.code === "charge_already_refunded") {
									return Promise.resolve();
								}
								throw err;
							});
					}),
				);

				// Update workshop status to cancelled
				return await trx
					.updateTable("club_activities")
					.set({ status: "cancelled" })
					.where("id", "=", id)
					.where("status", "=", "published")
					.returningAll()
					.executeTakeFirstOrThrow();
			},
		);
	}

	/**
	 * Check if a workshop can be edited (only 'planned' workshops can be edited)
	 */
	async canEdit(id: string): Promise<boolean> {
		this.logger.info("Checking if workshop can be edited", { workshopId: id });

		const workshop = await this.kysely
			.selectFrom("club_activities")
			.select(["status"])
			.where("id", "=", id)
			.executeTakeFirst();

		if (!workshop) {
			return false;
		}

		return workshop.status === "planned";
	}

	/**
	 * Check if workshop pricing can be edited
	 * Pricing can be edited if:
	 * - Workshop is in 'planned' status, OR
	 * - Workshop has no registrations yet
	 */
	async canEditPricing(id: string): Promise<boolean> {
		this.logger.info("Checking if workshop pricing can be edited", {
			workshopId: id,
		});

		// Get workshop status
		const workshop = await this.kysely
			.selectFrom("club_activities")
			.select(["status"])
			.where("id", "=", id)
			.executeTakeFirst();

		if (!workshop) {
			return false;
		}

		// If workshop is in planned status, pricing can always be edited
		if (workshop.status === "planned") {
			return true;
		}

		// For other statuses, check if there are any registrations
		const registrationCount = await this.kysely
			.selectFrom("club_activity_registrations")
			.select(this.kysely.fn.count("id").as("count"))
			.where("club_activity_id", "=", id)
			.executeTakeFirst();

		return Number(registrationCount?.count || 0) === 0;
	}

	// ========================================================================
	// Private Transactional Methods (for cross-service coordination)
	// ========================================================================

	/**
	 * Internal transactional method for finding workshop by ID
	 */
	async _findById(
		trx: Transaction<KyselyDatabase>,
		id: string,
	): Promise<Workshop> {
		const workshop = await trx
			.selectFrom("club_activities")
			.selectAll()
			.where("id", "=", id)
			.executeTakeFirst();

		if (!workshop) {
			throw new Error("Workshop not found", {
				cause: { workshopId: id, context: "WorkshopService._findById" },
			});
		}

		return workshop;
	}

	/**
	 * Internal transactional method for creating a workshop
	 */
	async _create(
		trx: Transaction<KyselyDatabase>,
		input: WorkshopInsert,
	): Promise<Workshop> {
		const workshopData = {
			...input,
			created_by: this.session.user.id,
		};

		return await trx
			.insertInto("club_activities")
			.values(workshopData)
			.returningAll()
			.executeTakeFirstOrThrow();
	}

	/**
	 * Internal transactional method for updating a workshop
	 */
	async _update(
		trx: Transaction<KyselyDatabase>,
		id: string,
		input: WorkshopUpdate,
	): Promise<Workshop> {
		return await trx
			.updateTable("club_activities")
			.set(input)
			.where("id", "=", id)
			.returningAll()
			.executeTakeFirstOrThrow();
	}
}
