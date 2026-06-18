import * as Sentry from "@sentry/sveltekit";
import type { Session } from "@supabase/supabase-js";
import { jwtDecode } from "jwt-decode";

export function getRolesFromSession(session: Session) {
	try {
		const tokenClaim = jwtDecode(session?.access_token);
		return new Set(
			(tokenClaim as { app_metadata: { roles: string[] } }).app_metadata
				?.roles || [],
		);
	} catch (error) {
		Sentry.captureMessage(`Error decoding token: ${error}`, "error");
		return new Set<string>();
	}
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

export const WORKSHOP_ROLES = new Set([
	"workshop_coordinator",
	"president",
	"admin",
]);

export const WAITLIST_ADMIN_ROLES = new Set([
	"admin",
	"president",
	"committee_coordinator",
	"beginners_coordinator",
	"coach",
]);

// Broad committee role set mirroring the `user_profiles` SELECT RLS policy
// and the Phoenix `members_admin_api` pipeline. Used by the members analytics
// read (issue #124).
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

export const INVENTORY_ROLES = new Set(["quartermaster", "admin", "president"]);

export const INVENTORY_READ_ROLES = new Set([...INVENTORY_ROLES, "member"]);
