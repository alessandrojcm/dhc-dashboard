import type { Database } from '$database';
import { sql, type QueryExecutorProvider } from 'kysely';

export function getMembershipInfo(
	userId: string,
	executor: QueryExecutorProvider
): Promise<Database['public']['CompositeTypes']['member_data_type']> {
	return sql<{
		get_membership_info: Database['public']['CompositeTypes']['member_data_type'];
	}>`select * from get_membership_info(${userId}::uuid)`
		.execute(executor)
		.then((r) => r.rows[0].get_membership_info);
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
	return sql<string>`select * from complete_member_registration(${v_user_id}::uuid, ${p_next_of_kin_name}::text, ${p_next_of_kin_phone}::text, ${p_insurance_form_submitted})`
		.execute(executor)
		.then((r) => r.rows[0]);
}

export function getMemberData(
	userId: string,
	executor: QueryExecutorProvider
): Promise<Database['public']['CompositeTypes']['member_data_type']> {
	return sql<
		Database['public']['CompositeTypes']['member_data_type']
	>`select * from get_member_data(${userId}::uuid)`
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
	}>`select * from update_member_data(
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
