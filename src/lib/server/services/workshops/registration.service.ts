import type { Stripe } from "stripe";
import type {
	Kysely,
	KyselyDatabase,
	Logger,
	RegistrationActor,
	Session,
	Transaction,
} from "../shared";
import { executeWithRLS } from "../shared";
import type {
	CancelRegistrationResult,
	CompleteRegistrationInput,
	CreatePaymentIntentInput,
	CreatePaymentIntentResult,
	Interest,
	Registration,
	RegistrationFilters,
	RegistrationWithUser,
	ToggleInterestResult,
} from "./types";

/**
 * Service for managing workshop registrations.
 *
 * Supports two actor contexts:
 * - `member`: Authenticated member performing actions on their own behalf
 * - `system`: System/service-level operations (e.g., public registration flow)
 *
 * The session is used for RLS claims (executeWithRLS), while the actor
 * determines identity for logging and business logic.
 */
export class RegistrationService {
	private logger: Logger;

	/**
	 * @param kysely - Database client
	 * @param session - Session for RLS claims (used by executeWithRLS)
	 * @param actor - Who is performing the operation (member or system)
	 * @param stripeClient - Stripe client for payment operations
	 * @param logger - Optional logger
	 */
	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		private actor: RegistrationActor,
		private stripeClient: Stripe,
		logger?: Logger,
	) {
		this.logger = logger ?? console;
	}

	// ============================================================================
	// Private Helpers
	// ============================================================================

	/**
	 * Returns the member user ID, or throws if the actor is not a member.
	 * Use this to guard member-only operations.
	 *
	 * @param context - Description of the operation for error messages
	 * @throws Error if actor is not a member
	 */
	private requireMemberUserId(context: string): string {
		if (this.actor.kind !== "member") {
			throw new Error(
				`Operation "${context}" requires a member context, but actor is "${this.actor.kind}"`,
			);
		}
		return this.actor.memberUserId;
	}

	/**
	 * Returns logging context based on actor type.
	 */
	private getActorLogContext(): Record<string, unknown> {
		if (this.actor.kind === "member") {
			return { actorKind: "member", userId: this.actor.memberUserId };
		}
		return { actorKind: "system" };
	}

	// ============================================================================
	// Query Methods
	// ============================================================================

	async findById(id: string): Promise<Registration> {
		this.logger.info("Fetching registration by ID", {
			registrationId: id,
			...this.getActorLogContext(),
		});

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				return this._findById(trx, id);
			},
		);
	}

	async findMany(filters?: RegistrationFilters): Promise<Registration[]> {
		this.logger.info("Fetching registrations", {
			filters,
			...this.getActorLogContext(),
		});

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				let query = trx.selectFrom("club_activity_registrations").selectAll();

				if (filters?.workshopId) {
					query = query.where("club_activity_id", "=", filters.workshopId);
				}
				if (filters?.memberId) {
					query = query.where("member_user_id", "=", filters.memberId);
				}
				if (filters?.status) {
					query = query.where("status", "=", filters.status);
				}

				return query.execute();
			},
		);
	}

	async getWorkshopAttendees(
		workshopId: string,
	): Promise<RegistrationWithUser[]> {
		this.logger.info("Fetching workshop attendees", {
			workshopId,
			...this.getActorLogContext(),
		});

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				const attendees = await trx
					.selectFrom("club_activity_registrations as car")
					.leftJoin(
						"user_profiles as up",
						"car.member_user_id",
						"up.supabase_user_id",
					)
					.leftJoin("external_users as eu", "car.external_user_id", "eu.id")
					.select([
						"car.id",
						"car.club_activity_id",
						"car.member_user_id",
						"car.external_user_id",
						"car.status",
						"car.attendance_status",
						"car.attendance_marked_at",
						"car.attendance_marked_by",
						"car.attendance_notes",
						"car.amount_paid",
						"car.stripe_checkout_session_id",
						"car.created_at",
						"car.updated_at",
						"car.cancelled_at",
						"car.confirmed_at",
						"car.currency",
						"car.registered_at",
						"car.registration_notes",
						"up.first_name as member_first_name",
						"up.last_name as member_last_name",
						"eu.first_name as external_first_name",
						"eu.last_name as external_last_name",
						"eu.email as external_email",
					])
					.where("car.club_activity_id", "=", workshopId)
					.where("car.status", "in", ["confirmed", "pending"])
					.orderBy("car.created_at", "asc")
					.execute();

				return attendees.map(
					(attendee) =>
						({
							id: attendee.id,
							club_activity_id: attendee.club_activity_id,
							member_user_id: attendee.member_user_id,
							external_user_id: attendee.external_user_id,
							status: attendee.status,
							cancelled_at: attendee.cancelled_at,
							currency: attendee.currency,
							registration_notes: attendee.registration_notes,
							confirmed_at: attendee.confirmed_at,
							registered_at: attendee.registered_at,
							attendance_status: attendee.attendance_status,
							attendance_marked_at: attendee.attendance_marked_at,
							attendance_marked_by: attendee.attendance_marked_by,
							attendance_notes: attendee.attendance_notes,
							amount_paid: attendee.amount_paid,
							stripe_checkout_session_id: attendee.stripe_checkout_session_id,
							created_at: attendee.created_at,
							updated_at: attendee.updated_at,
							user_profiles: attendee.member_first_name
								? {
										first_name: attendee.member_first_name,
										last_name: attendee.member_last_name!,
									}
								: null,
							external_users: attendee.external_first_name
								? {
										first_name: attendee.external_first_name,
										last_name: attendee.external_last_name!,
										email: attendee.external_email!,
									}
								: null,
						}) satisfies RegistrationWithUser,
				);
			},
		);
	}

	// ============================================================================
	// Member-Only Operations
	// ============================================================================

	/**
	 * Toggle interest in a workshop (member-only operation).
	 */
	async toggleInterest(workshopId: string): Promise<ToggleInterestResult> {
		const memberUserId = this.requireMemberUserId(
			"RegistrationService.toggleInterest",
		);

		this.logger.info("Toggling interest", {
			workshopId,
			...this.getActorLogContext(),
		});

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				const workshop = await trx
					.selectFrom("club_activities")
					.select(["id", "status"])
					.where("id", "=", workshopId)
					.executeTakeFirst();

				if (!workshop) {
					throw new Error("Workshop not found", {
						cause: {
							workshopId,
							context: "RegistrationService.toggleInterest",
						},
					});
				}

				if (workshop.status !== "planned") {
					throw new Error("Can only express interest in planned workshops", {
						cause: {
							workshopId,
							status: workshop.status,
							context: "RegistrationService.toggleInterest",
						},
					});
				}

				const existing = await trx
					.selectFrom("club_activity_interest")
					.selectAll()
					.where("club_activity_id", "=", workshopId)
					.where("user_id", "=", memberUserId)
					.executeTakeFirst();

				if (existing) {
					await trx
						.deleteFrom("club_activity_interest")
						.where("id", "=", existing.id)
						.execute();
					return {
						interest: null,
						message: "Interest withdrawn successfully",
						action: "withdrawn",
					};
				}

				const newInterest = await trx
					.insertInto("club_activity_interest")
					.values({
						club_activity_id: workshopId,
						user_id: memberUserId,
					})
					.returningAll()
					.executeTakeFirstOrThrow();

				return {
					interest: newInterest as Interest,
					message: "Interest expressed successfully",
					action: "expressed",
				};
			},
		);
	}

	/**
	 * Create a payment intent for member workshop registration (member-only operation).
	 */
	async createPaymentIntent(
		input: CreatePaymentIntentInput,
	): Promise<CreatePaymentIntentResult> {
		const memberUserId = this.requireMemberUserId(
			"RegistrationService.createPaymentIntent",
		);

		const { workshopId, amount, currency = "eur", customerId } = input;
		this.logger.info("Creating payment intent", {
			workshopId,
			amount,
			...this.getActorLogContext(),
		});

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				const workshop = await trx
					.selectFrom("club_activities")
					.select(["id", "title", "status", "max_capacity"])
					.where("id", "=", workshopId)
					.executeTakeFirst();

				if (!workshop) {
					throw new Error("Workshop not found", {
						cause: {
							workshopId,
							context: "RegistrationService.createPaymentIntent",
						},
					});
				}

				if (workshop.status !== "published") {
					throw new Error("Workshop not available for registration", {
						cause: {
							workshopId,
							status: workshop.status,
							context: "RegistrationService.createPaymentIntent",
						},
					});
				}

				const existingRegistration = await trx
					.selectFrom("club_activity_registrations")
					.select(["id"])
					.where("club_activity_id", "=", workshopId)
					.where("member_user_id", "=", memberUserId)
					.where("status", "in", ["pending", "confirmed"])
					.executeTakeFirst();

				if (existingRegistration) {
					throw new Error("Already registered for this workshop", {
						cause: {
							workshopId,
							context: "RegistrationService.createPaymentIntent",
						},
					});
				}

				if (workshop.max_capacity) {
					const registrationCount = await trx
						.selectFrom("club_activity_registrations")
						.select((eb) => eb.fn.count("id").as("count"))
						.where("club_activity_id", "=", workshopId)
						.where("status", "in", ["pending", "confirmed"])
						.executeTakeFirst();

					if (Number(registrationCount?.count) >= workshop.max_capacity) {
						throw new Error("Workshop is full", {
							cause: {
								workshopId,
								context: "RegistrationService.createPaymentIntent",
							},
						});
					}
				}

				const paymentIntent = await this.stripeClient.paymentIntents.create({
					amount,
					currency,
					metadata: {
						workshop_id: workshopId,
						workshop_title: workshop.title,
						user_id: memberUserId,
						type: "workshop_registration",
						actor_type: "member",
					},
					automatic_payment_methods: { enabled: false },
					payment_method_types: ["card", "link"],
					...(customerId ? { customer: customerId } : {}),
				});

				return {
					clientSecret: paymentIntent.client_secret!,
					paymentIntentId: paymentIntent.id,
				};
			},
		);
	}

	/**
	 * Complete a member registration after payment (member-only operation).
	 */
	async completeRegistration(
		input: CompleteRegistrationInput,
	): Promise<Registration> {
		const memberUserId = this.requireMemberUserId(
			"RegistrationService.completeRegistration",
		);

		const { workshopId, paymentIntentId } = input;
		this.logger.info("Completing registration", {
			workshopId,
			paymentIntentId,
			...this.getActorLogContext(),
		});

		const paymentIntent =
			await this.stripeClient.paymentIntents.retrieve(paymentIntentId);

		if (paymentIntent.status !== "succeeded") {
			throw new Error("Payment not completed", {
				cause: {
					paymentIntentId,
					status: paymentIntent.status,
					context: "RegistrationService.completeRegistration",
				},
			});
		}

		if (paymentIntent.metadata.workshop_id !== workshopId) {
			throw new Error("Payment intent does not match workshop", {
				cause: {
					paymentIntentId,
					workshopId,
					context: "RegistrationService.completeRegistration",
				},
			});
		}

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				return await trx
					.insertInto("club_activity_registrations")
					.values({
						club_activity_id: workshopId,
						member_user_id: memberUserId,
						status: "confirmed",
						stripe_checkout_session_id: paymentIntentId,
						amount_paid: paymentIntent.amount,
						currency: paymentIntent.currency,
						confirmed_at: new Date().toISOString(),
						registered_at: new Date().toISOString(),
					})
					.returningAll()
					.executeTakeFirstOrThrow();
			},
		);
	}

	/**
	 * Cancel a member's registration (member-only operation).
	 */
	async cancelRegistration(
		workshopId: string,
	): Promise<CancelRegistrationResult> {
		const memberUserId = this.requireMemberUserId(
			"RegistrationService.cancelRegistration",
		);

		this.logger.info("Cancelling registration", {
			workshopId,
			...this.getActorLogContext(),
		});

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				const registration = await trx
					.selectFrom("club_activity_registrations")
					.selectAll()
					.where("club_activity_id", "=", workshopId)
					.where("member_user_id", "=", memberUserId)
					.where("status", "in", ["pending", "confirmed"])
					.executeTakeFirst();

				if (!registration) {
					throw new Error("Registration not found", {
						cause: {
							workshopId,
							userId: memberUserId,
							context: "RegistrationService.cancelRegistration",
						},
					});
				}

				const updated = await trx
					.updateTable("club_activity_registrations")
					.set({ status: "cancelled", cancelled_at: new Date().toISOString() })
					.where("id", "=", registration.id)
					.returningAll()
					.executeTakeFirstOrThrow();

				return { registration: updated, refundProcessed: false };
			},
		);
	}

	// ============================================================================
	// Transactional Methods (for cross-service coordination)
	// ============================================================================

	async _findById(
		trx: Transaction<KyselyDatabase>,
		id: string,
	): Promise<Registration> {
		const registration = await trx
			.selectFrom("club_activity_registrations")
			.selectAll()
			.where("id", "=", id)
			.executeTakeFirst();

		if (!registration) {
			throw new Error("Registration not found", {
				cause: {
					registrationId: id,
					context: "RegistrationService._findById",
				},
			});
		}

		return registration;
	}
}
