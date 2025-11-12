import { sql, type QueryExecutorProvider } from 'kysely';

export type InvitationInfo = {
	invitation_id: string;
	first_name: string;
	last_name: string;
	phone_number: string;
	date_of_birth: string;
	pronouns: string;
	gender: string;
	medical_conditions: string;
	status: string;
};

/**
 * Creates an invitation for a user
 */
export function createInvitation(
	{
		userId,
		email,
		firstName,
		lastName,
		dateOfBirth,
		phoneNumber,
		invitationType,
		waitlistId = null,
		expiresAt = null,
		metadata = null
	}: {
		userId: string;
		email: string;
		firstName: string;
		lastName: string;
		dateOfBirth: string | Date;
		phoneNumber: string;
		invitationType: 'workshop' | 'admin';
		waitlistId?: string | null;
		expiresAt?: Date | null;
		metadata?: Record<string, unknown> | null;
	},
	executor: QueryExecutorProvider
): Promise<string> {
	// Convert Date objects to ISO strings
	const dateOfBirthStr = dateOfBirth instanceof Date ? dateOfBirth.toISOString() : dateOfBirth;
	const expiresAtStr = expiresAt instanceof Date ? expiresAt.toISOString() : expiresAt;

	return sql<{
		create_invitation: string;
	}>`select * from create_invitation(
    ${userId}::uuid,
    ${email}::text,
    ${firstName}::text,
    ${lastName}::text,
    ${dateOfBirthStr}::timestamptz,
    ${phoneNumber}::text,
    ${invitationType}::text,
    ${waitlistId}::uuid,
    ${expiresAtStr}::timestamptz,
    ${metadata ? JSON.stringify(metadata) : null}::jsonb
  )`
		.execute(executor)
		.then((r) => r.rows[0].create_invitation);
}

/**
 * Updates the status of an invitation
 */
export function updateInvitationStatus(
	invitationId: string,
	status: 'pending' | 'accepted' | 'expired' | 'revoked',
	executor: QueryExecutorProvider
): Promise<boolean> {
	return sql<{
		update_invitation_status: boolean;
	}>`select * from update_invitation_status(
    ${invitationId}::uuid,
    ${status}::invitation_status
  )`
		.execute(executor)
		.then((r) => r.rows[0].update_invitation_status);
}

/**
 * Gets information about an invitation for a user
 */
export function getInvitationInfo(
	userId: string,
	executor: QueryExecutorProvider
): Promise<InvitationInfo | null> {
	return sql<{
		get_invitation_info: InvitationInfo;
	}>`select * from get_invitation_info(${userId}::uuid)`
		.execute(executor)
		.then((r) => r.rows[0]?.get_invitation_info || null);
}
