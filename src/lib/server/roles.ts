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

export const INVENTORY_ROLES = new Set(["quartermaster", "admin", "president"]);

export const INVENTORY_READ_ROLES = new Set([...INVENTORY_ROLES, "member"]);
