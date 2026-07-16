import { filterNavByRoles, navData } from "$lib/server/rbacRoles";
import type { LayoutServerLoad } from "./$types";
import { invariant } from "$lib/server/invariant";
import { apiClientOptions } from "$lib/server/api-client";
import { membersMe } from "@dhc/api-client";

export const load: LayoutServerLoad = async ({ locals }) => {
	const { session } = await locals.safeGetSession();
	invariant(!session, "Unauthorized");

	const response = await membersMe({
		...apiClientOptions(session),
		throwOnError: true,
	});
	const userRoles = response.data.data.roles;

	return {
		roles: userRoles,
		navData: filterNavByRoles(navData, userRoles),
	};
};
