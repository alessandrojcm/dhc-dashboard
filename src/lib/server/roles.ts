import type { Session } from '@supabase/supabase-js';
import { jwtDecode } from 'jwt-decode';

export function getRolesFromSession(session: Session) {
	try {
		const tokenClaim = jwtDecode(session?.access_token);
		return new Set((tokenClaim as { app_metadata: { roles: string[] } }).app_metadata?.roles || []);
	} catch (error) {
		console.error('Error decoding token:', error);
		return new Set();
	}
}

export const allowedToggleRoles = new Set(['president', 'admin', 'committee_coordinator']);

export const SETTINGS_ROLES = new Set(['president', 'committee_coordinator', 'admin']);
