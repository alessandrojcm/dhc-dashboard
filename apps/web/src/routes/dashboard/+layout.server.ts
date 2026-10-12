import { beginnersWorkshopAssignmentsList } from "@dhc/api-client";
import { apiClientOptions, type Cookies } from "#lib/server/api-client.js";
import { authorizationFor } from "#lib/server/authorization/index.js";
import type { LayoutServerLoad } from "./$types";
import { invariant } from "#lib/server/invariant.js";

export const load: LayoutServerLoad = async ({ locals, cookies }) => {
	const { session } = await locals.safeGetSession();
	invariant(!session, "Unauthorized");
	const access = authorizationFor(session);

	// GH-510: the sidebar receives navigation already filtered by the same
	// capability decisions the route guard and route loads use.
	return {
		navData: access.navigation({
			hasBeginnersWorkshopAssignments: access.can(
				"beginners.workshops.assigned.read",
			)
				? await hasBeginnersWorkshopAssignments(cookies)
				: false,
		}),
	};
};

/**
 * ALE-379: whether "My Beginners' Workshops" has anything to show. The entry
 * is a convenience, so a failed read hides it rather than failing the
 * dashboard.
 */
async function hasBeginnersWorkshopAssignments(
	cookies: Cookies,
): Promise<boolean> {
	try {
		const response = await beginnersWorkshopAssignmentsList(
			apiClientOptions(cookies),
		);
		return (response.data?.data.length ?? 0) > 0;
	} catch {
		return false;
	}
}
