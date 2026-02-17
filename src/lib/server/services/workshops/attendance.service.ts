/**
 * Attendance Service
 * Handles workshop attendance tracking and management
 */

import type {
	Kysely,
	KyselyDatabase,
	Logger,
	Session,
	Transaction,
} from "../shared";
import { executeWithRLS } from "../shared";
import type { AttendanceUpdate, AttendanceResult } from "./types";

// ============================================================================
// Attendance Service
// ============================================================================

export class AttendanceService {
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
	 * Get attendance records for a workshop
	 * Only returns confirmed registrations
	 */
	async getWorkshopAttendance(workshopId: string): Promise<AttendanceResult[]> {
		this.logger.info("Fetching workshop attendance", { workshopId });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				const results = await trx
					.selectFrom("club_activity_registrations")
					.select([
						"id",
						"club_activity_id",
						"member_user_id",
						"external_user_id",
						"attendance_status",
						"attendance_marked_at",
						"attendance_marked_by",
						"attendance_notes",
					])
					.where("club_activity_id", "=", workshopId)
					.where("status", "=", "confirmed")
					.execute();

				return results as AttendanceResult[];
			},
		);
	}

	// ========================================================================
	// Mutation Methods
	// ========================================================================

	/**
	 * Update attendance for multiple registrations
	 * Validates that the workshop has started before allowing updates
	 */
	async updateAttendance(
		workshopId: string,
		attendanceUpdates: AttendanceUpdate[],
	): Promise<AttendanceResult[]> {
		this.logger.info("Updating attendance", {
			workshopId,
			updateCount: attendanceUpdates.length,
		});

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				return this._updateAttendance(trx, workshopId, attendanceUpdates);
			},
		);
	}

	// ========================================================================
	// Private Transactional Methods (for cross-service coordination)
	// ========================================================================

	/**
	 * Internal transactional method for updating attendance
	 */
	async _updateAttendance(
		trx: Transaction<KyselyDatabase>,
		workshopId: string,
		attendanceUpdates: AttendanceUpdate[],
	): Promise<AttendanceResult[]> {
		// Verify workshop has started
		const workshop = await trx
			.selectFrom("club_activities")
			.select(["id", "start_date", "end_date"])
			.where("start_date", "<=", new Date().toISOString())
			.where("id", "=", workshopId)
			.executeTakeFirst();

		if (!workshop) {
			throw new Error(
				"Cannot update attendance for a workshop that has not started yet",
				{
					cause: {
						workshopId,
						context: "AttendanceService._updateAttendance",
					},
				},
			);
		}

		// Update each registration's attendance
		const results: AttendanceResult[] = [];

		for (const update of attendanceUpdates) {
			const result = await trx
				.updateTable("club_activity_registrations")
				.set({
					attendance_status: update.attendance_status,
					attendance_marked_at: new Date().toISOString(),
					attendance_marked_by: this.session.user.id,
					attendance_notes: update.notes || null,
				})
				.where("id", "=", update.registration_id)
				.where("club_activity_id", "=", workshopId)
				.returning([
					"id",
					"club_activity_id",
					"member_user_id",
					"external_user_id",
					"attendance_status",
					"attendance_marked_at",
					"attendance_marked_by",
					"attendance_notes",
				])
				.executeTakeFirst();

			if (result) {
				results.push(result as AttendanceResult);
			}
		}

		return results;
	}
}
