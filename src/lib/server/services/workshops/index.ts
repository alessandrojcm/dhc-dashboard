/**
 * Workshop Domain Public API
 * Exports services, types, and factory functions
 */

import type { Stripe } from "stripe";
import { stripeClient } from "$lib/server/stripe";
import type { Logger, Session } from "../shared";
import { getKyselyClient } from "../shared";
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
	CompleteRegistrationInput,
	CreatePaymentIntentInput,
	CreatePaymentIntentResult,
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
 * Create a RegistrationService instance
 *
 * @param platform - App platform with Hyperdrive connection
 * @param session - User session for RLS
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns RegistrationService instance
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
		stripe,
		logger ?? sentryLogger,
	);
}
