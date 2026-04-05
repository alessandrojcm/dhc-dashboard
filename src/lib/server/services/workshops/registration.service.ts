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
	CompleteExternalRegistrationInput,
	CompleteRegistrationInput,
	CreateExternalPaymentIntentInput,
	CreateExternalPaymentIntentResult,
	CreatePaymentIntentInput,
	CreatePaymentIntentResult,
	ExternalUserInput,
	Interest,
	Registration,
	RegistrationFilters,
	RegistrationWithUser,
	ToggleInterestResult,
} from "./types";
import { ExternalRegistrationError } from "./types";
import dayjs from "dayjs";

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

	/**
	 * Validates workshop exists and is eligible for external registration.
	 * All validation is performed in a single SQL query for efficiency.
	 * Returns the workshop if valid, otherwise throws ExternalRegistrationError.
	 */
	private async validateWorkshopForExternalRegistration(
		trx: Transaction<KyselyDatabase>,
		workshopId: string,
	): Promise<{
		id: string;
		title: string;
		max_capacity: number;
		price_non_member: number;
	}> {
		const workshop = await trx
			.selectFrom("club_activities")
			.select(["id", "title", "max_capacity", "price_non_member"])
			.where("id", "=", workshopId)
			.where("status", "=", "published")
			.where("is_public", "=", true)
			.where("price_non_member", "is not", null)
			.where("price_non_member", ">=", 0)
			.executeTakeFirst();

		if (!workshop) {
			this.logger.warn("Workshop validation failed for external registration", {
				workshopId,
				...this.getActorLogContext(),
			});
			throw new ExternalRegistrationError(
				"WORKSHOP_NOT_FOUND",
				"Workshop not found or not available for registration",
				{ workshopId },
			);
		}

		return workshop;
	}

	/**
	 * Checks if the workshop has capacity for more registrations.
	 * @returns true if there's capacity, false if full
	 */
	private async checkWorkshopCapacity(
		trx: Transaction<KyselyDatabase>,
		workshopId: string,
		maxCapacity: number,
	): Promise<boolean> {
		const registrationCount = await trx
			.selectFrom("club_activity_registrations")
			.select((eb) => eb.fn.count("id").as("count"))
			.where("club_activity_id", "=", workshopId)
			.where("status", "in", ["pending", "confirmed"])
			.executeTakeFirst();

		return Number(registrationCount?.count ?? 0) < maxCapacity;
	}

	/**
	 * Checks for existing external user registration for a workshop.
	 * @returns The existing registration if found, otherwise undefined
	 */
	private async findExistingExternalRegistration(
		trx: Transaction<KyselyDatabase>,
		workshopId: string,
		externalUserId: string,
	): Promise<Registration | undefined> {
		return trx
			.selectFrom("club_activity_registrations")
			.selectAll()
			.where("club_activity_id", "=", workshopId)
			.where("external_user_id", "=", externalUserId)
			.where("status", "in", ["pending", "confirmed"])
			.executeTakeFirst();
	}

	/**
	 * Finds or creates an external user by normalized email.
	 * If the email exists, updates the profile fields.
	 * @returns The external user ID
	 */
	private async upsertExternalUser(
		trx: Transaction<KyselyDatabase>,
		input: ExternalUserInput,
	): Promise<string> {
		const normalizedEmail = input.email.trim().toLowerCase();

		const existingUser = await trx
			.selectFrom("external_users")
			.select(["id"])
			.where("email", "=", normalizedEmail)
			.executeTakeFirst();

		if (existingUser) {
			// Update profile fields if user exists
			await trx
				.updateTable("external_users")
				.set({
					first_name: input.firstName,
					last_name: input.lastName,
					phone_number: input.phoneNumber ?? null,
					updated_at: dayjs().toISOString(),
				})
				.where("id", "=", existingUser.id)
				.execute();

			return existingUser.id;
		}

		// Insert new external user
		const newUser = await trx
			.insertInto("external_users")
			.values({
				email: normalizedEmail,
				first_name: input.firstName,
				last_name: input.lastName,
				phone_number: input.phoneNumber ?? null,
			})
			.returning(["id"])
			.executeTakeFirstOrThrow();

		return newUser.id;
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
						confirmed_at: dayjs().toISOString(),
						registered_at: dayjs().toISOString(),
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
					.set({ status: "cancelled", cancelled_at: dayjs().toISOString() })
					.where("id", "=", registration.id)
					.returningAll()
					.executeTakeFirstOrThrow();

				return { registration: updated, refundProcessed: false };
			},
		);
	}

	// ============================================================================
	// External Registration Operations (for public/system flows)
	// ============================================================================

	/**
	 * Create a payment intent for external (non-member) workshop registration.
	 *
	 * This method:
	 * - Validates the workshop exists, is published, and is public
	 * - Derives the amount server-side from workshop's price_non_member (never trusts client amount)
	 * - Performs soft capacity check (fast reject if full)
	 * - Creates/updates the external user record
	 * - Creates a Stripe payment intent with appropriate metadata
	 *
	 * @param input - Workshop ID and external user details
	 * @returns Payment intent details including client secret and server-derived amount
	 * @throws ExternalRegistrationError for business rule violations
	 */
	async createExternalPaymentIntent(
		input: CreateExternalPaymentIntentInput,
	): Promise<CreateExternalPaymentIntentResult> {
		const { workshopId, externalUser, currency = "eur" } = input;
		const normalizedEmail = externalUser.email.trim().toLowerCase();

		this.logger.info("Creating external payment intent", {
			workshopId,
			externalEmail: normalizedEmail,
			...this.getActorLogContext(),
		});

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				// Validate workshop eligibility
				const workshop = await this.validateWorkshopForExternalRegistration(
					trx,
					workshopId,
				);

				// Soft capacity check
				const hasCapacity = await this.checkWorkshopCapacity(
					trx,
					workshopId,
					workshop.max_capacity,
				);

				if (!hasCapacity) {
					throw new ExternalRegistrationError(
						"WORKSHOP_FULL",
						"Workshop has reached maximum capacity",
						{ workshopId, maxCapacity: workshop.max_capacity },
					);
				}

				// Upsert external user
				const externalUserId = await this.upsertExternalUser(trx, externalUser);

				// Check for existing registration
				const existingRegistration =
					await this.findExistingExternalRegistration(
						trx,
						workshopId,
						externalUserId,
					);

				if (existingRegistration) {
					throw new ExternalRegistrationError(
						"ALREADY_REGISTERED",
						"This email is already registered for this workshop",
						{ workshopId, externalEmail: normalizedEmail },
					);
				}

				// Server-derived amount from workshop price_non_member (in cents)
				const amount = workshop.price_non_member;

				// Create Stripe payment intent
				const paymentIntent = await this.stripeClient.paymentIntents.create({
					amount,
					currency,
					receipt_email: normalizedEmail,
					metadata: {
						type: "workshop_registration",
						actor_type: "external",
						workshop_id: workshopId,
						workshop_title: workshop.title,
						external_user_id: externalUserId,
						external_email_normalized: normalizedEmail,
					},
					automatic_payment_methods: { enabled: false },
					payment_method_types: ["card", "link"],
				});

				return {
					clientSecret: paymentIntent.client_secret!,
					paymentIntentId: paymentIntent.id,
					amount,
					currency,
				};
			},
		);
	}

	/**
	 * Complete an external registration after payment success.
	 *
	 * This method:
	 * - Validates the payment intent succeeded and metadata matches
	 * - Performs hard capacity check with row-level consideration
	 * - Creates or updates the registration record
	 * - Is idempotent: retrying with the same payment intent returns existing registration
	 *
	 * @param input - Workshop ID, payment intent ID, and external user details
	 * @returns The created or existing registration
	 * @throws ExternalRegistrationError for business rule violations
	 */
	async completeExternalRegistration(
		input: CompleteExternalRegistrationInput,
	): Promise<Registration> {
		const { workshopId, paymentIntentId, externalUser } = input;
		const normalizedEmail = externalUser.email.trim().toLowerCase();

		this.logger.info("Completing external registration", {
			workshopId,
			paymentIntentId,
			externalEmail: normalizedEmail,
			...this.getActorLogContext(),
		});

		// Retrieve and validate payment intent
		const paymentIntent =
			await this.stripeClient.paymentIntents.retrieve(paymentIntentId);

		if (paymentIntent.status !== "succeeded") {
			throw new ExternalRegistrationError(
				"PAYMENT_NOT_COMPLETED",
				"Payment has not been completed",
				{ paymentIntentId, status: paymentIntent.status },
			);
		}

		// Validate payment intent metadata matches the request
		const metadata = paymentIntent.metadata;
		if (
			metadata.type !== "workshop_registration" ||
			metadata.actor_type !== "external" ||
			metadata.workshop_id !== workshopId ||
			metadata.external_email_normalized !== normalizedEmail
		) {
			throw new ExternalRegistrationError(
				"PAYMENT_METADATA_MISMATCH",
				"Payment intent does not match the registration request",
				{
					paymentIntentId,
					workshopId,
					externalEmail: normalizedEmail,
					metadataWorkshopId: metadata.workshop_id,
					metadataEmail: metadata.external_email_normalized,
				},
			);
		}

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				// Upsert external user (may have changed name/phone since intent creation)
				const externalUserId = await this.upsertExternalUser(trx, externalUser);

				// Check if registration already exists for this payment intent (idempotent success)
				const existingByPaymentIntent = await trx
					.selectFrom("club_activity_registrations")
					.selectAll()
					.where("stripe_checkout_session_id", "=", paymentIntentId)
					.executeTakeFirst();

				if (existingByPaymentIntent) {
					// Idempotent: return existing registration
					this.logger.info("Returning existing registration (idempotent)", {
						registrationId: existingByPaymentIntent.id,
						paymentIntentId,
						...this.getActorLogContext(),
					});
					return existingByPaymentIntent;
				}

				// Check for existing active registration by external user
				const existingRegistration =
					await this.findExistingExternalRegistration(
						trx,
						workshopId,
						externalUserId,
					);

				if (existingRegistration) {
					// If existing registration has different payment intent, it's a duplicate attempt
					if (
						existingRegistration.stripe_checkout_session_id !== paymentIntentId
					) {
						throw new ExternalRegistrationError(
							"ALREADY_REGISTERED",
							"This email is already registered for this workshop",
							{
								workshopId,
								externalEmail: normalizedEmail,
								existingRegistrationId: existingRegistration.id,
							},
						);
					}
					// Same payment intent - return existing (idempotent)
					return existingRegistration;
				}

				// Re-validate workshop for completion (hard check)
				const workshop = await this.validateWorkshopForExternalRegistration(
					trx,
					workshopId,
				);

				// Hard capacity check
				const hasCapacity = await this.checkWorkshopCapacity(
					trx,
					workshopId,
					workshop.max_capacity,
				);

				if (!hasCapacity) {
					throw new ExternalRegistrationError(
						"WORKSHOP_FULL",
						"Workshop has reached maximum capacity",
						{ workshopId, maxCapacity: workshop.max_capacity },
					);
				}

				const now = dayjs().toISOString();

				// Create new registration
				const registration = await trx
					.insertInto("club_activity_registrations")
					.values({
						club_activity_id: workshopId,
						external_user_id: externalUserId,
						member_user_id: null,
						status: "confirmed",
						stripe_checkout_session_id: paymentIntentId,
						amount_paid: paymentIntent.amount,
						currency: paymentIntent.currency,
						confirmed_at: now,
						registered_at: now,
					})
					.returningAll()
					.executeTakeFirstOrThrow();

				this.logger.info("Created external registration", {
					registrationId: registration.id,
					workshopId,
					externalUserId,
					...this.getActorLogContext(),
				});

				return registration;
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
