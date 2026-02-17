/**
 * Invitation Domain Public API
 * Exports services, types, and factory functions
 */

import { getKyselyClient } from "../shared";
import { sentryLogger } from "../shared/logger";
import type { Logger, Session } from "../shared";
import { InvitationService } from "./invitation.service";

// Export service class
export { InvitationService } from "./invitation.service";

// Export validation schemas
export {
	InvitationCreateSchema,
	InvitationStatusUpdateSchema,
} from "./invitation.service";

// Export types
export type {
	InvitationCreateInput,
	InvitationStatusUpdateInput,
} from "./invitation.service";

export type {
	Invitation,
	InvitationInfo,
	InvitationStatus,
	InvitationType,
	CreateInvitationArgs,
} from "./types";

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create an InvitationService instance
 *
 * @param platform - App platform with Hyperdrive connection
 * @param session - User session for RLS (optional for public methods like getInvitationInfo)
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns InvitationService instance
 *
 * @example
 * ```typescript
 * // With session (for protected methods)
 * const invitationService = createInvitationService(platform, session);
 * const invitations = await invitationService.findMany();
 *
 * // Without session (for public methods)
 * const invitationService = createInvitationService(platform, null);
 * const info = await invitationService.getInvitationInfo(invitationId);
 * ```
 */
export function createInvitationService(
	platform: App.Platform,
	session: Session | null = null,
	logger?: Logger,
): InvitationService {
	return new InvitationService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		logger ?? sentryLogger,
	);
}
