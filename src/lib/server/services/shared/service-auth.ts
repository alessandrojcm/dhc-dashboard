/**
 * Service Authentication Utilities
 *
 * Provides helpers for service-level authentication contexts,
 * separating RLS claims from actor identity.
 */

import type { Session } from "@supabase/supabase-js";

// ============================================================================
// Actor Types
// ============================================================================

/**
 * Represents who is performing an operation in the service layer.
 *
 * - `member`: An authenticated member performing an action on their own behalf
 * - `system`: A system/service-level operation (e.g., public registration flow)
 */
export type RegistrationActor =
	| { kind: "member"; memberUserId: string }
	| { kind: "system" };

// ============================================================================
// Service Role Session
// ============================================================================

/**
 * Creates a service-role backed session-like object for use with executeWithRLS.
 *
 * This allows public/system flows to execute database operations with
 * service-role privileges while keeping the same RLS execution pattern.
 *
 * @param serviceRoleKey - The Supabase service role JWT key
 * @throws Error if serviceRoleKey is not provided
 * @returns A Session-like object with service role access token
 *
 * @example
 * ```typescript
 * import { env } from '$env/dynamic/private';
 *
 * const serviceSession = buildServiceRoleSession(env.SERVICE_ROLE_KEY);
 * const result = await executeWithRLS(kysely, { claims: serviceSession }, async (trx) => {
 *   // ... operations with service role privileges
 * });
 * ```
 */
export function buildServiceRoleSession(serviceRoleKey: string): Session {
	if (!serviceRoleKey) {
		throw new Error(
			"serviceRoleKey is required. Cannot create service role session.",
		);
	}

	// The service role key IS the JWT token for service role access
	// We construct a minimal Session object that satisfies executeWithRLS requirements
	return {
		access_token: serviceRoleKey,
		refresh_token: "",
		expires_in: 0,
		expires_at: 0,
		token_type: "bearer",
		user: {
			id: "service-role",
			aud: "authenticated",
			role: "service_role",
			email: "",
			email_confirmed_at: undefined,
			phone: "",
			confirmed_at: undefined,
			last_sign_in_at: undefined,
			app_metadata: { provider: "service_role" },
			user_metadata: {},
			identities: [],
			created_at: "",
			updated_at: "",
		},
	};
}

/**
 * Options for creating a public/system registration service.
 */
export interface PublicServiceOptions {
	/**
	 * Override the claims session for testing purposes.
	 * If provided, this session will be used instead of building from serviceRoleKey.
	 */
	claimsSession?: Session;
}
