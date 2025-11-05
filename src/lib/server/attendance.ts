import { executeWithRLS, getKyselyClient } from './kysely';
import type { Session } from '@supabase/supabase-js';
import type { Database } from '$database';

export type AttendanceUpdate = {
	registration_id: string;
	attendance_status: 'attended' | 'no_show' | 'excused';
	notes?: string;
};

type AttendanceResult = Pick<
	Database['public']['Tables']['club_activity_registrations']['Row'],
	| 'id'
	| 'club_activity_id'
	| 'member_user_id'
	| 'external_user_id'
	| 'attendance_status'
	| 'attendance_marked_at'
	| 'attendance_marked_by'
	| 'attendance_notes'
>;

export async function getWorkshopAttendance(
	workshopId: string,
	session: Session,
	platform: App.Platform
): Promise<AttendanceResult[]> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);

	return await executeWithRLS(kysely, { claims: session }, async (trx) => {
		const results = await trx
			.selectFrom('club_activity_registrations')
			.select([
				'id',
				'club_activity_id',
				'member_user_id',
				'external_user_id',
				'attendance_status',
				'attendance_marked_at',
				'attendance_marked_by',
				'attendance_notes'
			])
			.where('club_activity_id', '=', workshopId)
			.where('status', '=', 'confirmed')
			.execute();

		return results;
	});
}

export async function updateAttendance(
	workshopId: string,
	attendanceUpdates: AttendanceUpdate[],
	session: Session,
	platform: App.Platform
): Promise<AttendanceResult[]> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);

	return await executeWithRLS(kysely, { claims: session }, async (trx) => {
		const results = [];
		const workshop = await trx
			.selectFrom('club_activities')
			.select(['id', 'start_date', 'end_date'])
			.where('start_date', '<=', new Date().toISOString())
			.where('id', '=', workshopId)
			.executeTakeFirst();
		if (!workshop) {
			throw new Error('Cannot update attendance for a workshop that has not started yet');
		}

		for (const update of attendanceUpdates) {
			const result = await trx
				.updateTable('club_activity_registrations')
				.set({
					attendance_status: update.attendance_status,
					attendance_marked_at: new Date().toISOString(),
					attendance_marked_by: session.user.id,
					attendance_notes: update.notes || null
				})
				.where('id', '=', update.registration_id)
				.where('club_activity_id', '=', workshopId)
				.returning([
					'id',
					'club_activity_id',
					'member_user_id',
					'external_user_id',
					'attendance_status',
					'attendance_marked_at',
					'attendance_marked_by',
					'attendance_notes'
				])
				.executeTakeFirst();

			if (result) {
				results.push(result);
			}
		}

		return results;
	});
}
