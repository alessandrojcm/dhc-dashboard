/**
 * Workshop Domain Types
 * Type definitions for workshop-related entities
 */

import type { Database } from "$database";

// ============================================================================
// Database Table Types
// ============================================================================

export type Workshop = Database["public"]["Tables"]["club_activities"]["Row"];
export type WorkshopInsert =
	Database["public"]["Tables"]["club_activities"]["Insert"];
export type WorkshopUpdate =
	Database["public"]["Tables"]["club_activities"]["Update"];

export type Registration =
	Database["public"]["Tables"]["club_activity_registrations"]["Row"];
export type RegistrationInsert =
	Database["public"]["Tables"]["club_activity_registrations"]["Insert"];
export type RegistrationUpdate =
	Database["public"]["Tables"]["club_activity_registrations"]["Update"];

export type Refund =
	Database["public"]["Tables"]["club_activity_refunds"]["Row"];
export type RefundInsert =
	Database["public"]["Tables"]["club_activity_refunds"]["Insert"];
export type RefundUpdate =
	Database["public"]["Tables"]["club_activity_refunds"]["Update"];

// ============================================================================
// Enums
// ============================================================================

export type WorkshopStatus = "planned" | "published" | "cancelled" | "finished";
export type RegistrationStatus =
	| "pending"
	| "confirmed"
	| "cancelled"
	| "refunded";
export type AttendanceStatus = "attended" | "no_show" | "excused" | null;
export type RefundStatus = "pending" | "processing" | "completed" | "failed";

// ============================================================================
// Service Input/Output Types
// ============================================================================

/**
 * Workshop with related data (attendees, refunds, etc.)
 */
export interface WorkshopWithRelations extends Workshop {
	attendees?: Registration[];
	refunds?: Refund[];
}

/**
 * Registration with user profile data
 */
export interface RegistrationWithUser extends Registration {
	user_profiles?: {
		first_name: string;
		last_name: string;
	} | null;
	external_users?: {
		first_name: string;
		last_name: string;
		email: string;
	} | null;
}

/**
 * Refund with user profile data
 */
export interface RefundWithUser extends Refund {
	user_profiles?: {
		first_name: string;
		last_name: string;
	} | null;
	external_users?: {
		first_name: string;
		last_name: string;
		email: string;
	} | null;
}

/**
 * Attendance update input
 */
export interface AttendanceUpdate {
	registration_id: string;
	attendance_status: "attended" | "no_show" | "excused";
	notes?: string;
}

/**
 * Attendance result
 */
export interface AttendanceResult {
	id: string;
	club_activity_id: string;
	member_user_id: string | null;
	external_user_id: string | null;
	attendance_status: AttendanceStatus;
	attendance_marked_at: string | null;
	attendance_marked_by: string | null;
	attendance_notes: string | null;
}

/**
 * Workshop filters for queries
 */
export interface WorkshopFilters {
	status?: WorkshopStatus;
	startDateFrom?: Date;
	startDateTo?: Date;
	createdBy?: string;
	isPublic?: boolean;
}

/**
 * Registration filters for queries
 */
export interface RegistrationFilters {
	workshopId?: string;
	memberId?: string;
	status?: RegistrationStatus;
}

/**
 * Refund eligibility check result
 */
export interface RefundEligibility {
	eligible: boolean;
	reason?: string;
	registration?: {
		id: string;
		amount_paid: number;
		stripe_checkout_session_id: string | null;
		status: string;
	};
	workshop?: {
		start_date: string;
		refund_days: number | null;
		status: string;
	};
}

// ============================================================================
// Interest Types
// ============================================================================

export type Interest =
	Database["public"]["Tables"]["club_activity_interest"]["Row"];
export type InterestInsert =
	Database["public"]["Tables"]["club_activity_interest"]["Insert"];

/**
 * Result of toggling interest on a workshop
 */
export interface ToggleInterestResult {
	interest: Interest | null;
	message: string;
	action: "expressed" | "withdrawn";
}

// ============================================================================
// Payment Intent Types
// ============================================================================

/**
 * Input for creating a payment intent
 */
export interface CreatePaymentIntentInput {
	workshopId: string;
	amount: number;
	currency?: string;
	customerId?: string;
}

/**
 * Result of creating a payment intent
 */
export interface CreatePaymentIntentResult {
	clientSecret: string;
	paymentIntentId: string;
}

/**
 * Input for completing a registration
 */
export interface CompleteRegistrationInput {
	workshopId: string;
	paymentIntentId: string;
}

/**
 * Result of cancelling a registration
 */
export interface CancelRegistrationResult {
	registration: Registration;
	refundProcessed: boolean;
}
