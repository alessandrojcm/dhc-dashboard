import type {
	Kysely,
	KyselyDatabase,
	Logger,
	Session,
	Transaction,
} from "../shared";
import { executeWithRLS } from "../shared";
import { stripeClient } from "$lib/server/stripe";
import type {
	Registration,
	RegistrationFilters,
	RegistrationWithUser,
	Interest,
	ToggleInterestResult,
	CreatePaymentIntentInput,
	CreatePaymentIntentResult,
	CompleteRegistrationInput,
	CancelRegistrationResult,
} from "./types";

export class RegistrationService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		logger?: Logger,
	) {
		this.logger = logger ?? console;
	}

	async findById(id: string): Promise<Registration> {
		this.logger.info("Fetching registration by ID", { registrationId: id });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				return this._findById(trx, id);
			},
		);
	}

	async findMany(filters?: RegistrationFilters): Promise<Registration[]> {
		this.logger.info("Fetching registrations", { filters });

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
		this.logger.info("Fetching workshop attendees", { workshopId });

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

	async toggleInterest(workshopId: string): Promise<ToggleInterestResult> {
		this.logger.info("Toggling interest", {
			workshopId,
			userId: this.session.user.id,
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
					.where("user_id", "=", this.session.user.id)
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
						user_id: this.session.user.id,
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

	async createPaymentIntent(
		input: CreatePaymentIntentInput,
	): Promise<CreatePaymentIntentResult> {
		const { workshopId, amount, currency = "eur", customerId } = input;
		this.logger.info("Creating payment intent", {
			workshopId,
			amount,
			userId: this.session.user.id,
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
					.where("member_user_id", "=", this.session.user.id)
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

				const paymentIntent = await stripeClient.paymentIntents.create({
					amount,
					currency,
					metadata: {
						workshop_id: workshopId,
						workshop_title: workshop.title,
						user_id: this.session.user.id,
						type: "workshop_registration",
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

	async completeRegistration(
		input: CompleteRegistrationInput,
	): Promise<Registration> {
		const { workshopId, paymentIntentId } = input;
		this.logger.info("Completing registration", {
			workshopId,
			paymentIntentId,
			userId: this.session.user.id,
		});

		const paymentIntent =
			await stripeClient.paymentIntents.retrieve(paymentIntentId);

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
						member_user_id: this.session.user.id,
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

	async cancelRegistration(
		workshopId: string,
	): Promise<CancelRegistrationResult> {
		this.logger.info("Cancelling registration", {
			workshopId,
			userId: this.session.user.id,
		});

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				const registration = await trx
					.selectFrom("club_activity_registrations")
					.selectAll()
					.where("club_activity_id", "=", workshopId)
					.where("member_user_id", "=", this.session.user.id)
					.where("status", "in", ["pending", "confirmed"])
					.executeTakeFirst();

				if (!registration) {
					throw new Error("Registration not found", {
						cause: {
							workshopId,
							userId: this.session.user.id,
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
