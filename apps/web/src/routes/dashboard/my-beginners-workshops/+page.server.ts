import { beginnersWorkshopAssignmentsList } from "@dhc/api-client";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorizationFor } from "#lib/server/authorization/index.js";
import type { PageServerLoad } from "./$types";

/** ALE-379: the member's own upcoming and same-day Staff assignments. */
export const load: PageServerLoad = async ({ locals, cookies }) => {
	const { session } = await locals.safeGetSession();
	authorizationFor(session).require("beginners.workshops.assigned.read");

	const response = await beginnersWorkshopAssignmentsList({
		...apiClientOptions(cookies),
		throwOnError: true,
	});

	return { assignments: response.data.data };
};
