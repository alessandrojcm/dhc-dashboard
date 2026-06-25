import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";

export const load = async ({
	locals,
}: {
	locals: App.Locals;
}) => {
	// The Inventory Item list filter options (categories + containers) and
	// the item rows themselves are now served by Phoenix and consumed
	// browser-side via `@dhc/api-client`:
	//   - filter options: `GET /api/inventory/items/filters` (issue ALE-98)
	//   - item rows: `GET /api/inventory/items` (issue ALE-99)
	// The Supabase JWT is attached by `configureClient`'s `getAuthToken` hook;
	// authz is enforced by Phoenix's `inventory_admin_api` pipeline, so no
	// redundant server-side read is needed here. The layout's
	// `authorize(INVENTORY_ROLES)` still gates page access.
	await authorize(locals, INVENTORY_ROLES);
	return {};
};
