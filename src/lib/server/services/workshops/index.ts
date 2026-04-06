/**
 * Workshop Domain Public API
 * Exports services, types, and factory functions
 */

import { env } from "$env/dynamic/private";
import type { Stripe } from "stripe";
import { stripeClient } from "$lib/server/stripe";
import type { Logger, PublicServiceOptions, Session } from "../shared";
import { buildServiceRoleSession, getKyselyClient } from "../shared";
import { sentryLogger } from "../shared/logger";
import { AttendanceService } from "./attendance.service";
import { RefundService } from "./refund.service";
import { RegistrationService } from "./registration.service";
import { WorkshopService } from "./workshop.service";

// ============================================================================
// Service Exports
// ============================================================================

export { AttendanceService } from "./attendance.service";
export { RefundService } from "./refund.service";
export { RegistrationService } from "./registration.service";
export { WorkshopService } from "./workshop.service";

// ============================================================================
// Validation Schema Exports
// ============================================================================

export type {
	CreateWorkshopInput,
	UpdateWorkshopInput,
} from "./workshop.service";
export {
	BaseWorkshopSchema,
	CreateWorkshopSchema,
	UpdateWorkshopSchema,
} from "./workshop.service";

// ============================================================================
// Type Exports
// ============================================================================

export type {
	AttendanceResult,
	AttendanceStatus,
	AttendanceUpdate,
	CancelRegistrationResult,
	CompleteExternalRegistrationInput,
	CompleteRegistrationInput,
	CreateExternalPaymentIntentInput,
	CreateExternalPaymentIntentResult,
	CreatePaymentIntentInput,
	CreatePaymentIntentResult,
	ExternalRegistrationErrorCode,
	ExternalRegistrationGateResult,
	ExternalRegistrationWorkshop,
	ExternalUserInput,
	Interest,
	InterestInsert,
	Refund,
	RefundEligibility,
	RefundInsert,
	RefundStatus,
	RefundUpdate,
	RefundWithUser,
	Registration,
	RegistrationFilters,
	RegistrationGateReason,
	RegistrationInsert,
	RegistrationStatus,
	RegistrationUpdate,
	RegistrationWithUser,
	ToggleInterestResult,
	Workshop,
	WorkshopFilters,
	WorkshopInsert,
	WorkshopStatus,
	WorkshopUpdate,
	WorkshopWithRelations,
} from "./types";

export { ExternalRegistrationError } from "./types";

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create a WorkshopService instance
 *
 * @param platform - App platform with Hyperdrive connection
 * @param session - User session for RLS
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns WorkshopService instance
 *
 * @example
 * ```typescript
 * const workshopService = createWorkshopService(platform, session);
 * const workshop = await workshopService.findById(workshopId);
 * ```
 */
export function createWorkshopService(
	platform: App.Platform,
	session: Session,
	stripe: Stripe = stripeClient,
	logger?: Logger,
): WorkshopService {
	return new WorkshopService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		stripe,
		logger ?? sentryLogger,
	);
}

/**
 * Create an AttendanceService instance
 *
 * @param platform - App platform with Hyperdrive connection
 * @param session - User session for RLS
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns AttendanceService instance
 *
 * @example
 * ```typescript
 * const attendanceService = createAttendanceService(platform, session);
 * const attendance = await attendanceService.getWorkshopAttendance(workshopId);
 * ```
 */
export function createAttendanceService(
	platform: App.Platform,
	session: Session,
	logger?: Logger,
): AttendanceService {
	return new AttendanceService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		logger ?? sentryLogger,
	);
}

/**
 * Create a RefundService instance
 *
 * @param platform - App platform with Hyperdrive connection
 * @param session - User session for RLS
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns RefundService instance
 *
 * @example
 * ```typescript
 * const refundService = createRefundService(platform, session);
 * const refunds = await refundService.getWorkshopRefunds(workshopId);
 * ```
 */
export function createRefundService(
	platform: App.Platform,
	session: Session,
	stripe: Stripe = stripeClient,
	logger?: Logger,
): RefundService {
	return new RefundService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		stripe,
		logger ?? sentryLogger,
	);
}

/**
 * Create a RegistrationService instance for authenticated member operations.
 *
 * This factory creates a service with a `member` actor context, where the
 * member's identity is derived from the session's user ID.
 *
 * @param platform - App platform with Hyperdrive connection
 * @param session - User session for RLS and member identity
 * @param stripe - Optional Stripe client (defaults to stripeClient)
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns RegistrationService instance configured for member operations
 *
 * @example
 * ```typescript
 * const registrationService = createRegistrationService(platform, session);
 * const attendees = await registrationService.getWorkshopAttendees(workshopId);
 * ```
 */
export function createRegistrationService(
	platform: App.Platform,
	session: Session,
	stripe: Stripe = stripeClient,
	logger?: Logger,
): RegistrationService {
	return new RegistrationService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		{ kind: "member", memberUserId: session.user.id },
		stripe,
		logger ?? sentryLogger,
	);
}

/**
 * Create a RegistrationService instance for public/system operations.
 *
 * This factory creates a service with a `system` actor context, using
 * service-role credentials for RLS. Use this for public registration flows
 * where no authenticated member session exists.
 *
 * @param platform - App platform with Hyperdrive connection
 * @param stripe - Optional Stripe client (defaults to stripeClient)
 * @param logger - Optional logger (defaults to sentryLogger)
 * @param opts - Optional configuration (e.g., override claims session for testing)
 * @returns RegistrationService instance configured for system/public operations
 *
 * @example
 * ```typescript
 * // In a public route handler
 * const registrationService = createPublicRegistrationService(platform);
 * const result = await registrationService.createExternalPaymentIntent({
 *   workshopId: 'uuid',
 *   externalUser: { firstName: 'John', lastName: 'Doe', email: 'john@example.com' }
 * });
 * ```
 */
export function createPublicRegistrationService(
	platform: App.Platform,
	stripe: Stripe = stripeClient,
	logger?: Logger,
	opts?: PublicServiceOptions,
): RegistrationService {
	const claimsSession =
		opts?.claimsSession ?? buildServiceRoleSession(env.SERVICE_ROLE_KEY);

	return new RegistrationService(
		getKyselyClient(platform.env.HYPERDRIVE),
		claimsSession,
		{ kind: "system" },
		stripe,
		logger ?? sentryLogger,
	);
}
