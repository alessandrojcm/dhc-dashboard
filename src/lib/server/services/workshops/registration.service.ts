/**
 * Registration Service
 * Handles workshop registration queries and management
 */

import type {
	Kysely,
	KyselyDatabase,
	Logger,
	Session,
	Transaction,
} from "../shared";
import { executeWithRLS } from "../shared";
import type {
	Registration,
	RegistrationFilters,
	RegistrationWithUser,
} from "./types";

// ============================================================================
// Registration Service
// ============================================================================

export class RegistrationService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		logger?: Logger,
	) {
		this.logger = logger ?? console;
	}

	// ========================================================================
	// Query Methods
	// ========================================================================

	/**
	 * Find registration by ID
	 */
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

	/**
	 * Find multiple registrations with optional filters
	 */
	async findMany(filters?: RegistrationFilters): Promise<Registration[]> {
		this.logger.info("Fetching registrations", { filters });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				let query = trx
					.selectFrom("club_activity_registrations")
					.selectAll();

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

	/**
	 * Get workshop attendees with user profile data
	 */
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

				// Transform to include user profile data
				return attendees.map((attendee) => ({
					id: attendee.id,
					club_activity_id: attendee.club_activity_id,
					member_user_id: attendee.member_user_id,
					external_user_id: attendee.external_user_id,
					status: attendee.status,
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
								last_name: attendee.member_last_name,
							}
						: null,
					external_users: attendee.external_first_name
						? {
								first_name: attendee.external_first_name,
								last_name: attendee.external_last_name,
								email: attendee.external_email!,
							}
						: null,
				}));
			},
		);
	}

	// ========================================================================
	// Private Transactional Methods (for cross-service coordination)
	// ========================================================================

	/**
	 * Internal transactional method for finding registration by ID
	 */
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
