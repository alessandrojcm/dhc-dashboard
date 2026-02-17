/**
 * Member Domain Services
 *
 * Provides member and profile management functionality:
 * - MemberService: Member data CRUD operations
 * - ProfileService: Profile updates with Stripe integration
 *
 * @example Basic usage in data.remote.ts
 * ```typescript
 * import { form, getRequestEvent } from '$app/server';
 * import { createMemberService, MemberUpdateSchema } from '$lib/server/services/members';
 *
 * export const updateProfile = form(MemberUpdateSchema, async (data) => {
 *   const event = getRequestEvent();
 *   const { session } = await event.locals.safeGetSession();
 *
 *   const memberService = createMemberService(event.platform!, session!);
 *   const member = await memberService.update(userId, data);
 *
 *   return { success: 'Profile updated!' };
 * });
 * ```
 *
 * @example Using ProfileService with Stripe sync
 * ```typescript
 * import { createProfileService, MemberUpdateSchema } from '$lib/server/services/members';
 *
 * const profileService = createProfileService(platform, session);
 * const member = await profileService.updateProfile(userId, form.data);
 * ```
 */

import type { Session } from "@supabase/supabase-js";
import type Stripe from "stripe";
import type { Logger } from "../shared";
import { getKyselyClient, sentryLogger } from "../shared";
import { MemberService } from "./member.service";
import { ProfileService } from "./profile.service";
import { WaitlistService } from "./waitlist.service";
import { stripeClient } from "$lib/server/stripe";

// Re-export services
export { MemberService } from "./member.service";
export { ProfileService } from "./profile.service";
export { WaitlistService } from "./waitlist.service";

// Re-export types and schemas
export type {
	MemberData,
	MemberWithSubscription,
	MemberUpdateInput,
	UpdateMemberDataArgs,
} from "./member.service";

export { MemberUpdateSchema } from "./member.service";

export type {
	WaitlistEntry,
	WaitlistEntryInsert,
	WaitlistEntryUpdate,
	WaitlistStatus,
	WaitlistGuardian,
	WaitlistGuardianInsert,
	WaitlistGuardianUpdate,
	InsertWaitlistEntryResult,
} from "./waitlist-types";

export {
	WaitlistEntrySchema,
	type WaitlistEntryInput,
	calculateAge,
	isMinor,
} from "./waitlist.service";

// ============================================================================
// Factory Functions
// ============================================================================

/**
 * Create a MemberService instance
 *
 * @param platform - App platform with HYPERDRIVE connection
 * @param session - Supabase session for RLS
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns MemberService instance
 *
 * @example
 * ```typescript
 * const memberService = createMemberService(platform, session);
 * const member = await memberService.findById(userId);
 * ```
 */
export function createMemberService(
	platform: App.Platform,
	session: Session,
	logger?: Logger,
): MemberService {
	return new MemberService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		logger ?? sentryLogger,
	);
}

/**
 * Create a ProfileService instance
 *
 * @param platform - App platform with HYPERDRIVE connection
 * @param session - Supabase session for RLS
 * @param stripe - Stripe client instance (defaults to stripeClient)
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns ProfileService instance
 *
 * @example
 * ```typescript
 * const profileService = createProfileService(platform, session);
 * await profileService.updateProfile(userId, profileData);
 * ```
 */
export function createProfileService(
	platform: App.Platform,
	session: Session,
	stripe?: Stripe,
	logger?: Logger,
): ProfileService {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const effectiveLogger = logger ?? sentryLogger;
	const effectiveStripe = stripe ?? stripeClient;

	return new ProfileService(
		kysely,
		session,
		effectiveStripe,
		effectiveLogger,
		new MemberService(kysely, session, effectiveLogger),
	);
}

/**
 * Create a WaitlistService instance
 *
 * @param platform - App platform with HYPERDRIVE connection
 * @param logger - Optional logger (defaults to sentryLogger)
 * @returns WaitlistService instance
 *
 * @example
 * ```typescript
 * const waitlistService = createWaitlistService(platform);
 * const result = await waitlistService.create(waitlistData);
 * ```
 */
export function createWaitlistService(
	platform: App.Platform,
	logger?: Logger,
): WaitlistService {
	return new WaitlistService(
		getKyselyClient(platform.env.HYPERDRIVE),
		logger ?? sentryLogger,
	);
}
