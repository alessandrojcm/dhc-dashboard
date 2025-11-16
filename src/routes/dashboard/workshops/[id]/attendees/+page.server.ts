import { error } from "@sveltejs/kit";
import { authorize } from "$lib/server/auth";
import { getKyselyClient } from "$lib/server/kysely";
import { WORKSHOP_ROLES } from "$lib/server/roles";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ params, locals, platform }) => {
	await authorize(locals, WORKSHOP_ROLES);

	const kysely = getKyselyClient(platform?.env.HYPERDRIVE!);
	const workshopId = params.id;

	// Run all queries in parallel for better performance
	const [workshop, attendeesData, refundsData] = await Promise.all([
		// Verify the workshop exists and get refund policy
		kysely
			.selectFrom("club_activities")
			.select(["id", "title", "status", "start_date", "refund_days"])
			.where("id", "=", workshopId)
			.executeTakeFirst(),

		// Load attendees with proper joins
		kysely
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
				"car.status",
				"car.attendance_status",
				"car.attendance_marked_at",
				"car.attendance_marked_by",
				"car.attendance_notes",
				"up.first_name as member_first_name",
				"up.last_name as member_last_name",
				"eu.first_name as external_first_name",
				"eu.last_name as external_last_name",
				"eu.email as external_email",
			])
			.where("car.club_activity_id", "=", workshopId)
			.where("car.status", "in", ["confirmed", "pending"])
			.orderBy("car.created_at", "asc")
			.execute(),

		// Load refunds with proper joins
		kysely
			.selectFrom("club_activity_refunds as ref")
			.innerJoin(
				"club_activity_registrations as car",
				"ref.registration_id",
				"car.id",
			)
			.leftJoin(
				"user_profiles as up",
				"car.member_user_id",
				"up.supabase_user_id",
			)
			.leftJoin("external_users as eu", "car.external_user_id", "eu.id")
			.select([
				"ref.id",
				"ref.registration_id",
				"ref.refund_amount",
				"ref.refund_reason",
				"ref.status",
				"ref.created_at",
				"up.first_name as member_first_name",
				"up.last_name as member_last_name",
				"eu.first_name as external_first_name",
				"eu.last_name as external_last_name",
				"eu.email as external_email",
			])
			.where("car.club_activity_id", "=", workshopId)
			.orderBy("ref.created_at", "desc")
			.execute(),
	]);

	if (!workshop) {
		error(404, {
			message: "Workshop not found",
		});
	}

	// Transform attendees data with proper typing
	const transformedAttendees = attendeesData.map((attendee) => ({
		id: attendee.id,
		club_activity_id: attendee.club_activity_id,
		status: attendee.status,
		attendance_status: attendee.attendance_status,
		attendance_marked_at: attendee.attendance_marked_at,
		attendance_marked_by: attendee.attendance_marked_by,
		attendance_notes: attendee.attendance_notes,
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

	// Transform refunds data with proper typing
	const transformedRefunds = refundsData.map((refund) => ({
		id: refund.id,
		registration_id: refund.registration_id,
		refund_amount: refund.refund_amount,
		refund_reason: refund.refund_reason,
		status: refund.status,
		created_at: refund.created_at,
		user_profiles: refund.member_first_name
			? {
					first_name: refund.member_first_name,
					last_name: refund.member_last_name,
				}
			: null,
		external_users: refund.external_first_name
			? {
					first_name: refund.external_first_name,
					last_name: refund.external_last_name,
					email: refund.external_email!,
				}
			: null,
	}));

	return {
		workshop,
		attendees: transformedAttendees,
		refunds: transformedRefunds,
	};
};
