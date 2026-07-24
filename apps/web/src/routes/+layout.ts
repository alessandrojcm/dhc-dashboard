import type { LayoutLoad } from "./$types";

/**
 * ALE-164: the dashboard authenticates through the Phoenix Session cookie.
 * The Supabase browser client is no longer constructed here; the session
 * projection is read from the layout data (populated by the root
 * `+layout.server.ts` via `GET /api/auth/session`).
 *
 * The `depends("supabase:auth")` call is replaced with a Phoenix-session
 * dependency key so `invalidateAll()` / `invalidate("phoenix:session")` can
 * trigger a session re-read.
 */
export const load: LayoutLoad = async ({ data, depends }) => {
	depends("phoenix:session");

	return {
		session: data.session,
	};
};
