import type { Database } from '$database';
import { sql, type QueryExecutorProvider } from 'kysely';
import { type BeginnersFormSchema } from '$lib/schemas/beginnersWaitlist';

type GetInvitationInfoResult = {
	invitation_id: string;
	first_name: string;
	last_name: string;
	phone_number: string;
	date_of_birth: string;
	pronouns: string;
	gender: Database['public']['Enums']['gender'];
	medical_conditions: string;
	status: Database['public']['Enums']['invitation_status'];
	user_id: string;
	email: string;
};

export function getMembershipInfo(
	userId: string,
	executor: QueryExecutorProvider
): Promise<Database['public']['CompositeTypes']['member_data_type']> {
	return sql<{
		get_membership_info: Database['public']['CompositeTypes']['member_data_type'];
	}>`select *
		 from get_membership_info(${userId}::uuid)`
		.execute(executor)
		.then((r) => r.rows[0].get_membership_info);
}

export function insertWaitlistEntry(
	formData: BeginnersFormSchema,
	executor: QueryExecutorProvider
) {
	return sql<Database['public']['Functions']['insert_waitlist_entry']['Returns'][0]>`select *
		 from insert_waitlist_entry(
			 ${formData.firstName},
			 ${formData.lastName},
			 ${formData.email},
			 ${formData.dateOfBirth.toISOString()},
			 ${formData.phoneNumber},
			 ${formData.pronouns.toLowerCase()},
			 ${formData.gender},
			 ${formData.medicalConditions},
			 ${formData.socialMediaConsent}
					)`
		.execute(executor)
		.then((r) => r.rows[0]);
}

export function getInvitationInfo(
	invitationId: string,
	executor: QueryExecutorProvider
): Promise<GetInvitationInfoResult> {
	return sql<{
		get_invitation_info: GetInvitationInfoResult;
	}>`select *
		 from get_invitation_info(${invitationId}::uuid)`
		.execute(executor)
		.then((r) => r.rows[0].get_invitation_info);
}

export function createInvitation(
	{
		email,
		invitationType,
		waitlistId = null,
		expiresAt = null,
		metadata = null,
		userId,
		firstName,
		lastName,
		dateOfBirth,
		phoneNumber
	}: {
		email: string;
		invitationType: 'workshop' | 'admin';
		waitlistId?: string | null;
		expiresAt?: Date | null;
		metadata?: Record<string, unknown> | null;
		userId: string;
		firstName: string;
		lastName: string;
		dateOfBirth: string;
		phoneNumber: string;
	},
	executor: QueryExecutorProvider
): Promise<string> {
	return sql<{
		create_invitation: string;
	}>`select *
		 from create_invitation(
			 ${userId}::uuid,
			 ${email}::text,
			 ${firstName}::text,
			 ${lastName}::text,
			 ${dateOfBirth}::timestamptz,
			 ${phoneNumber}::text,
			 ${invitationType}::text,
			 ${waitlistId}::uuid,
			 ${expiresAt}::timestamptz,
			 ${metadata ? JSON.stringify(metadata) : null}::jsonb
					)`
		.execute(executor)
		.then((r) => r.rows[0].create_invitation);
}

export function updateInvitationStatus(
	invitationId: string,
	status: 'pending' | 'accepted' | 'expired' | 'revoked',
	executor: QueryExecutorProvider
): Promise<boolean> {
	return sql<{
		update_invitation_status: boolean;
	}>`select *
		 from update_invitation_status(
			 ${invitationId}::uuid,
			 ${status}::invitation_status
					)`
		.execute(executor)
		.then((r) => r.rows[0].update_invitation_status);
}

export function completeMemberRegistration(
	{
		v_user_id,
		p_next_of_kin_name,
		p_next_of_kin_phone,
		p_insurance_form_submitted
	}: Database['public']['Functions']['complete_member_registration']['Args'],
	executor: QueryExecutorProvider
): Promise<string> {
	return sql<string>`select *
										 from complete_member_registration(${v_user_id}::uuid, ${p_next_of_kin_name}::text,
																											 ${p_next_of_kin_phone}::text, ${p_insurance_form_submitted})`
		.execute(executor)
		.then((r) => r.rows[0]);
}

export function getMemberData(
	userId: string,
	executor: QueryExecutorProvider
): Promise<Database['public']['CompositeTypes']['member_data_type']> {
	return sql<Database['public']['CompositeTypes']['member_data_type']>`select *
		from get_member_data(${userId}::uuid)`
		.execute(executor)
		.then((r) => r.rows[0]);
}

export function updateMemberData(
	{
		user_uuid,
		p_first_name,
		p_last_name,
		p_is_active,
		p_medical_conditions,
		p_phone_number,
		p_gender,
		p_pronouns,
		p_date_of_birth,
		p_next_of_kin_name,
		p_next_of_kin_phone,
		p_preferred_weapon,
		p_membership_start_date,
		p_membership_end_date,
		p_last_payment_date,
		p_insurance_form_submitted,
		p_additional_data,
		p_social_media_consent = 'no' as Database['public']['Enums']['social_media_consent']
	}: Database['public']['Functions']['update_member_data']['Args'],
	executor: QueryExecutorProvider
): Promise<Database['public']['CompositeTypes']['member_data_type']> {
	return sql<{
		update_member_data: Database['public']['CompositeTypes']['member_data_type'];
	}>`select *
		 from update_member_data(
			 ${user_uuid}::uuid,
			 ${p_first_name ?? null}::text,
			 ${p_last_name ?? null}::text,
			 ${p_is_active ?? null}::boolean,
			 ${p_medical_conditions ?? null}::text,
			 ${p_phone_number ?? null}::text,
			 ${p_gender ?? null}::gender,
			 ${p_pronouns ?? null}::text,
			 ${p_date_of_birth ?? null}::date,
			 ${p_next_of_kin_name ?? null}::text,
			 ${p_next_of_kin_phone ?? null}::text,
			 ${p_preferred_weapon ?? null}::preferred_weapon[],
			 ${p_membership_start_date ?? null}::timestamptz,
			 ${p_membership_end_date ?? null}::timestamptz,
			 ${p_last_payment_date ?? null}::timestamptz,
			 ${p_insurance_form_submitted ?? null}::boolean,
			 ${p_additional_data ?? null}::jsonb,
			 ${p_social_media_consent ?? 'no'}::social_media_consent
					)`
		.execute(executor)
		.then((r) => r.rows[0].update_member_data);
}

export function moveCancelledAttendeeToWaitlist(
	attendeeId: string,
	workshopId: string,
	executor: QueryExecutorProvider,
	adminNotes?: string
): Promise<string> {
	return sql<{
		move_cancelled_attendee_to_waitlist: string;
	}>`select *
		 from move_cancelled_attendee_to_waitlist(
			 ${attendeeId}::uuid,
			 ${workshopId}::uuid,
			 ${adminNotes ?? null}::text
				)`
		.execute(executor)
		.then((r) => r.rows[0].move_cancelled_attendee_to_waitlist);
}

export function getPrioritizedWaitlistForWorkshop(
	workshopId: string,
	executor: QueryExecutorProvider,
	limit?: number
): Promise<Array<{
	waitlist_id: string;
	email: string;
	user_profile_id: string;
	first_name: string;
	last_name: string;
	phone_number: string;
	priority_level: number;
	created_at: string;
	admin_notes: string;
}>> {
	return sql<{
		waitlist_id: string;
		email: string;
		user_profile_id: string;
		first_name: string;
		last_name: string;
		phone_number: string;
		priority_level: number;
		created_at: string;
		admin_notes: string;
	}>`select *
		 from get_prioritized_waitlist_for_workshop(
			 ${workshopId}::uuid,
			 ${limit ?? null}::integer
				)`
		.execute(executor)
		.then((r) => r.rows);
}

export function resetWaitlistPriorityAfterWorkshop(
	workshopId: string,
	executor: QueryExecutorProvider
): Promise<void> {
	return sql`select reset_waitlist_priority_after_workshop(${workshopId}::uuid)`
		.execute(executor)
		.then(() => undefined);
}
