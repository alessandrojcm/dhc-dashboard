import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";

export const load = async ({ locals }: { locals: App.Locals }) => {
	// Both Inventory reads are now served by Phoenix and consumed browser-side
	// via `@dhc/api-client`:
	//   - overview counts: `GET /api/inventory/overview` (issue ALE-94)
	//   - activity feed:   `GET /api/inventory/activity` (issue ALE-95)
	// The Supabase JWT is attached by `configureClient`'s `getAuthToken` hook;
	// authz is enforced by Phoenix's `inventory_admin_api` pipeline, so no
	// redundant server-side read is needed here. The layout's
	// `authorize(INVENTORY_READ_ROLES)` still gates page access.
	await authorize(locals, INVENTORY_ROLES);
	return {};
};
