/**
 * Invitation Domain Types
 * Type definitions for invitation-related operations
 */

import type { Database } from "$database";

/**
 * Invitation status enum
 */
export type InvitationStatus = Database["public"]["Enums"]["invitation_status"];

/**
 * Invitation type
 */
export type InvitationType = "workshop" | "admin";

/**
 * Invitation row from database
 */
export type Invitation = Database["public"]["Tables"]["invitations"]["Row"];

/**
 * Invitation insert type
 */
export type InvitationInsert =
	Database["public"]["Tables"]["invitations"]["Insert"];

/**
 * Invitation update type
 */
export type InvitationUpdate =
	Database["public"]["Tables"]["invitations"]["Update"];

/**
 * Result from get_invitation_info RPC function
 */
export type InvitationInfo = {
	invitation_id: string;
	first_name: string;
	last_name: string;
	phone_number: string;
	date_of_birth: string;
	pronouns: string;
	gender: Database["public"]["Enums"]["gender"];
	medical_conditions: string;
	status: InvitationStatus;
	user_id: string;
	email: string;
};

/**
 * Arguments for create_invitation RPC function
 */
export type CreateInvitationArgs =
	Database["public"]["Functions"]["create_invitation"]["Args"];
