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
	CompleteExternalRegistrationFromCheckoutSessionInput,
	CompleteRegistrationInput,
	CreateExternalCheckoutSessionInput,
	CreateExternalCheckoutSessionResult,
	CreatePaymentIntentInput,
	CreatePaymentIntentResult,
	ExternalRegistrationGateResult,
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
	 * Get registration gate status for a workshop (public route gating).
	 *
	 * This method checks workshop eligibility for external registration without
	 * creating any payment or registration records. It's used by public routes
	 * to determine whether to show the registration form.
	 *
	 * @param workshopId - Workshop UUID
	 * @returns Gate status object with eligibility info and workshop details
	 */
	async getExternalRegistrationGate(
		workshopId: string,
	): Promise<ExternalRegistrationGateResult> {
		this.logger.info("Checking external registration gate", {
			workshopId,
			...this.getActorLogContext(),
		});

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				// Fetch workshop with all eligibility checks
				const workshop = await trx
					.selectFrom("club_activities")
					.select([
						"id",
						"title",
						"description",
						"start_date",
						"end_date",
						"location",
						"price_non_member",
						"max_capacity",
						"status",
						"is_public",
					])
					.where("id", "=", workshopId)
					.executeTakeFirst();

				// Workshop not found
				if (!workshop) {
					return { canRegister: false, reason: "NOT_FOUND" };
				}

				// Workshop not published
				if (workshop.status !== "published") {
					return { canRegister: false, reason: "NOT_PUBLISHED" };
				}

				// Workshop not public
				if (!workshop.is_public) {
					return { canRegister: false, reason: "NOT_PUBLIC" };
				}

				// No external price set
				if (
					workshop.price_non_member === null ||
					workshop.price_non_member < 0
				) {
					return { canRegister: false, reason: "NO_EXTERNAL_PRICE" };
				}

				// Check capacity
				const hasCapacity = await this.checkWorkshopCapacity(
					trx,
					workshopId,
					workshop.max_capacity,
				);

				if (!hasCapacity) {
					return { canRegister: false, reason: "FULL" };
				}

				// Workshop is eligible for registration
				return {
					canRegister: true,
					workshop: {
						id: workshop.id,
						title: workshop.title,
						description: workshop.description,
						start_date: workshop.start_date,
						end_date: workshop.end_date,
						location: workshop.location,
						price_non_member: workshop.price_non_member,
						max_capacity: workshop.max_capacity,
					},
				};
			},
		);
	}

	/**
	 * Create a checkout session for external (non-member) workshop registration.
	 */
	async createExternalCheckoutSession(
		input: CreateExternalCheckoutSessionInput,
	): Promise<CreateExternalCheckoutSessionResult> {
		const { workshopId, returnUrl } = input;

		if (!returnUrl.includes("{CHECKOUT_SESSION_ID}")) {
			throw new ExternalRegistrationError(
				"INVALID_INPUT",
				"returnUrl must include {CHECKOUT_SESSION_ID} placeholder",
				{ workshopId, returnUrl },
			);
		}

		this.logger.info("Creating external checkout session", {
			workshopId,
			...this.getActorLogContext(),
		});

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				const workshop = await this.validateWorkshopForExternalRegistration(
					trx,
					workshopId,
				);

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

				const checkoutSession =
					await this.stripeClient.checkout.sessions.create({
						mode: "payment",
						ui_mode: "embedded",
						return_url: returnUrl,
						customer_creation: "if_required",
						name_collection: {
							individual: {
								enabled: true,
								optional: false,
							},
						},
						invoice_creation: { enabled: true },
						payment_method_types: ["card", "link", "sepa_debit"],
						phone_number_collection: { enabled: true },
						line_items: [
							{
								quantity: 1,
								price_data: {
									currency: "eur",
									unit_amount: workshop.price_non_member,
									product_data: {
										name: workshop.title,
									},
								},
							},
						],
						metadata: {
							type: "workshop_registration",
							actor_type: "external",
							workshop_id: workshopId,
						},
					});

				if (!checkoutSession.client_secret) {
					throw new ExternalRegistrationError(
						"PAYMENT_NOT_COMPLETED",
						"Stripe checkout client secret was not returned",
						{ workshopId, checkoutSessionId: checkoutSession.id },
					);
				}

				return {
					checkoutSessionId: checkoutSession.id,
					checkoutClientSecret: checkoutSession.client_secret,
					checkoutUrl: checkoutSession.url ?? null,
				};
			},
		);
	}

	/**
	 * Complete external registration by validating a Stripe Checkout Session.
	 */
	async completeExternalRegistrationFromCheckoutSession(
		input: CompleteExternalRegistrationFromCheckoutSessionInput,
	): Promise<Registration> {
		const { workshopId, checkoutSessionId } = input;

		this.logger.info("Completing external registration from checkout session", {
			workshopId,
			checkoutSessionId,
			...this.getActorLogContext(),
		});

		let checkoutSession: Stripe.Checkout.Session;
		try {
			checkoutSession = await this.stripeClient.checkout.sessions.retrieve(
				checkoutSessionId,
				{ expand: ["payment_intent"] },
			);
		} catch (error) {
			throw new ExternalRegistrationError(
				"CHECKOUT_SESSION_NOT_FOUND",
				"Checkout session not found",
				{
					checkoutSessionId,
					workshopId,
					error: error instanceof Error ? error.message : String(error),
				},
			);
		}

		if (
			checkoutSession.status !== "complete" ||
			checkoutSession.payment_status !== "paid"
		) {
			throw new ExternalRegistrationError(
				"PAYMENT_NOT_COMPLETED",
				"Payment has not been completed",
				{
					checkoutSessionId,
					status: checkoutSession.status,
					paymentStatus: checkoutSession.payment_status,
				},
			);
		}

		const metadata = checkoutSession.metadata ?? {};
		if (
			metadata.type !== "workshop_registration" ||
			metadata.actor_type !== "external" ||
			metadata.workshop_id !== workshopId
		) {
			throw new ExternalRegistrationError(
				"PAYMENT_METADATA_MISMATCH",
				"Checkout session does not match the registration request",
				{
					checkoutSessionId,
					workshopId,
					metadataType: metadata.type,
					metadataActorType: metadata.actor_type,
					metadataWorkshopId: metadata.workshop_id,
				},
			);
		}

		const customerEmail =
			checkoutSession.customer_details?.email ?? checkoutSession.customer_email;
		const customerName = checkoutSession.customer_details?.name?.trim() ?? "";
		const customerPhone = checkoutSession.customer_details?.phone ?? null;

		if (!customerEmail || customerName.length === 0) {
			throw new ExternalRegistrationError(
				"CUSTOMER_DETAILS_MISSING",
				"Missing customer details from checkout session",
				{ checkoutSessionId, hasEmail: !!customerEmail, customerName },
			);
		}

		const paymentIntentId =
			typeof checkoutSession.payment_intent === "string"
				? checkoutSession.payment_intent
				: checkoutSession.payment_intent?.id;

		if (paymentIntentId && customerEmail) {
			try {
				await this.stripeClient.paymentIntents.update(paymentIntentId, {
					receipt_email: customerEmail,
				});
			} catch (error) {
				this.logger.warn("Failed to set receipt email on payment intent", {
					paymentIntentId,
					checkoutSessionId,
					workshopId,
					error: error instanceof Error ? error.message : String(error),
					...this.getActorLogContext(),
				});
			}
		}

		const [firstName = "", ...lastNameParts] = customerName.split(/\s+/);
		if (firstName.length === 0) {
			throw new ExternalRegistrationError(
				"CUSTOMER_DETAILS_MISSING",
				"Missing customer name from checkout session",
				{ checkoutSessionId, customerName },
			);
		}
		const lastName = lastNameParts.join(" ");

		if (checkoutSession.amount_total === null) {
			throw new ExternalRegistrationError(
				"PAYMENT_METADATA_MISMATCH",
				"Checkout session amount is missing",
				{ checkoutSessionId, workshopId },
			);
		}

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				const externalUserId = await this.upsertExternalUser(trx, {
					firstName,
					lastName,
					email: customerEmail,
					phoneNumber: customerPhone,
				});

				const existingByCheckoutSession = await trx
					.selectFrom("club_activity_registrations")
					.selectAll()
					.where("stripe_checkout_session_id", "=", checkoutSessionId)
					.executeTakeFirst();

				if (existingByCheckoutSession) {
					this.logger.info(
						"Returning existing registration (idempotent checkout completion)",
						{
							registrationId: existingByCheckoutSession.id,
							checkoutSessionId,
							...this.getActorLogContext(),
						},
					);
					return existingByCheckoutSession;
				}

				const existingRegistration =
					await this.findExistingExternalRegistration(
						trx,
						workshopId,
						externalUserId,
					);

				if (existingRegistration) {
					if (
						existingRegistration.stripe_checkout_session_id !==
						checkoutSessionId
					) {
						throw new ExternalRegistrationError(
							"ALREADY_REGISTERED",
							"This email is already registered for this workshop",
							{
								workshopId,
								externalEmail: customerEmail,
								existingRegistrationId: existingRegistration.id,
							},
						);
					}
					return existingRegistration;
				}

				const workshop = await this.validateWorkshopForExternalRegistration(
					trx,
					workshopId,
				);

				const hasCapacity = await this.checkWorkshopCapacity(
					trx,
					workshopId,
					workshop.max_capacity,
				);

				if (!hasCapacity) {
					await this.stripeClient.refunds.create({
						charge: (checkoutSession.payment_intent as Stripe.PaymentIntent)
							.latest_charge as string,
						reason: "duplicate",
					});
					this.logger.warn(
						`Refunded payment for workshop ${workshopId} due to capacity reached`,
						{
							paymentIntentId: (
								checkoutSession.payment_intent as Stripe.PaymentIntent
							).id,
						},
					);
					throw new ExternalRegistrationError(
						"WORKSHOP_FULL",
						"Workshop has reached maximum capacity, your payment has been refunded.",
						{ workshopId, maxCapacity: workshop.max_capacity },
					);
				}

				if (checkoutSession.amount_total !== workshop.price_non_member) {
					throw new ExternalRegistrationError(
						"PAYMENT_METADATA_MISMATCH",
						"Checkout amount does not match workshop price",
						{
							checkoutSessionId,
							amountTotal: checkoutSession.amount_total,
							workshopPrice: workshop.price_non_member,
						},
					);
				}

				const now = dayjs().toISOString();
				const amountPaid = checkoutSession.amount_total;

				const registration = await trx
					.insertInto("club_activity_registrations")
					.values({
						club_activity_id: workshopId,
						external_user_id: externalUserId,
						member_user_id: null,
						status: "confirmed",
						stripe_checkout_session_id: checkoutSessionId,
						amount_paid: amountPaid,
						currency: checkoutSession.currency ?? "eur",
						confirmed_at: now,
						registered_at: now,
					})
					.returningAll()
					.executeTakeFirstOrThrow();

				this.logger.info("Created external registration", {
					registrationId: registration.id,
					workshopId,
					externalUserId,
					checkoutSessionId,
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
