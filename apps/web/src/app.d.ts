/// <reference types="@sveltejs/kit" />
import type { PhoenixSessionProjection } from "./lib/server/auth";
// See https://svelte.dev/docs/kit/types#app.d.ts
// for information about these interfaces
declare global {
	namespace App {
		// interface Error {}

		// ALE-164: the dashboard authenticates through the Phoenix Session
		// cookie. The `Session` type is the Phoenix session projection
		// (`{ principal: { id, email }, roles, capabilities }`), NOT a Supabase Session.
		interface Locals {
			/**
			 * Phoenix session projection for the current request, or `null`
			 * when there is no valid, active session. Populated by
			 * `safeGetSession()` in `hooks.server.ts`, which forwards the
			 * `_dhc_session` cookie to Phoenix `GET /api/auth/session`.
			 */
			session: PhoenixSessionProjection | null;
			/**
			 * Convenience accessor that returns the Phoenix session projection
			 * or `null` (re-runs the cookie check on demand). Kept for parity
			 * with the Supabase-era seam so server loads / remote functions
			 * that called `locals.safeGetSession()` keep working.
			 */
			safeGetSession: () => Promise<{
				session: PhoenixSessionProjection | null;
			}>;
		}
		interface PageData {
			session: PhoenixSessionProjection | null;
		}
		interface PageState {
			selectedSlug?: string;
			selectedLoanId?: string;
		}
	}
}
