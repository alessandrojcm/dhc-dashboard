import { type QueryExecutorProvider, sql } from "kysely";
import type { Database } from "$database";

export function getMembershipInfo(
	userId: string,
	executor: QueryExecutorProvider,
): Promise<Database["public"]["CompositeTypes"]["member_data_type"]> {
	return sql<{
		get_membership_info: Database["public"]["CompositeTypes"]["member_data_type"];
	}>`select *
		 from get_membership_info(${userId}::uuid)`
		.execute(executor)
		.then((r) => r.rows[0].get_membership_info);
}

// insertWaitlistEntry has been migrated to WaitlistService
// See: src/lib/server/services/members/waitlist.service.ts

// getInvitationInfo, createInvitation, and updateInvitationStatus have been migrated to InvitationService
// See: src/lib/server/services/invitations/invitation.service.ts

export function completeMemberRegistration(
	{
		v_user_id,
		p_next_of_kin_name,
		p_next_of_kin_phone,
		p_insurance_form_submitted,
	}: Database["public"]["Functions"]["complete_member_registration"]["Args"],
	executor: QueryExecutorProvider,
): Promise<string> {
	return sql<string>`select *
										 from complete_member_registration(${v_user_id}::uuid, ${p_next_of_kin_name}::text,
																											 ${p_next_of_kin_phone}::text, ${p_insurance_form_submitted})`
		.execute(executor)
		.then((r) => r.rows[0]);
}

// getMemberData and updateMemberData have been migrated to MemberService
// See: src/lib/server/services/members/member.service.ts
