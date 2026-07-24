/// <reference types="@sveltejs/kit" />
import type { SupabaseClient, Database } from "./database.types";
import { Env } from "../worker-configuration";
import type { PhoenixSessionProjection } from "./lib/server/auth";
// See https://svelte.dev/docs/kit/types#app.d.ts
// for information about these interfaces
declare global {
	namespace App {
		// interface Error {}

		interface Platform {
			env?: Env;
		}

		// ALE-164: the dashboard authenticates through the Phoenix Session
		// cookie. The `Session` type is the Phoenix session projection
		// (`{ principal: { id, email }, roles }`), NOT a Supabase Session.
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
		// interface PageState {}
		// interface Platform {}
	}
}

// ALE-164: the Supabase browser client is still constructed during the
// transition (the notification realtime bridge and E2E fixtures use it), but
// it is no longer the auth seam. `locals.supabase` is intentionally removed
// from `App.Locals`; the Supabase client is only referenced where its callers
// still own it (e.g. E2E helpers), not as a request-local dependency.
export type { SupabaseClient, Database };

declare module "$env/static/public" {
	export const PUBLIC_SUPABASE_URL: string;
	export const PUBLIC_SUPABASE_ANON_KEY: string;
	export const PUBLIC_SITE_URL: string;
	export const PUBLIC_STRIPE_KEY: string;
	export const PUBLIC_API_BASE_URL: string;
	export const PUBLIC_PHOENIX_SOCKET_URL: string;
}
