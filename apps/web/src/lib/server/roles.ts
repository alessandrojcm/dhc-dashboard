import type { PhoenixSessionProjection } from "$lib/server/auth";

/**
 * ALE-164: roles come from the Phoenix session projection, not from decoding
 * the Supabase JWT's `app_metadata.roles` claim. `getRolesFromSession` is kept
 * as a thin accessor so the existing call sites (guards, remote functions)
 * keep working with the new projection shape.
 */
export function getRolesFromSession(
	session: PhoenixSessionProjection | null,
): Set<string> {
	return new Set(session?.roles ?? []);
}

export const allowedToggleRoles = new Set([
	"president",
	"admin",
	"committee_coordinator",
]);

export const SETTINGS_ROLES = new Set([
	"president",
	"committee_coordinator",
	"admin",
]);

export const DISCORD_DOCTOR_ROLES = new Set([
	"admin",
	"president",
	"committee_coordinator",
]);

export const MEMBERS_ADMIN_ROLES = new Set([
	"admin",
	"president",
	"treasurer",
	"committee_coordinator",
	"sparring_coordinator",
	"workshop_coordinator",
	"beginners_coordinator",
	"quartermaster",
	"pr_manager",
	"volunteer_coordinator",
	"research_coordinator",
	"coach",
]);

/**
 * ALE-252: officers with billing authority who may mint membership charges
 * (reactivation). Mirrors the Phoenix `:membership_minting_api` pipeline;
 * deliberately narrower than MEMBERS_ADMIN_ROLES and with no self-service
 * fallback, because the command creates new Stripe charges.
 */
export const MEMBERSHIP_MINTING_ROLES = new Set([
	"admin",
	"president",
	"treasurer",
	"committee_coordinator",
]);

export const WORKSHOP_ROLES = new Set([
	"workshop_coordinator",
	"president",
	"admin",
]);

export const INVENTORY_ROLES = new Set(["quartermaster", "admin", "president"]);

export const INVENTORY_READ_ROLES = new Set([...INVENTORY_ROLES, "member"]);
