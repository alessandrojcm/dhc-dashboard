import { waitlistStatus } from "@dhc/api-client";
import { apiClientOptions } from "$lib/server/api-client";
import { invariant } from "$lib/server/invariant";
import { allowedToggleRoles, getRolesFromSession } from "$lib/server/roles";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, cookies, depends }) => {
	depends("wailist:status");
	const { session } = await locals.safeGetSession();
	invariant(session === null, "Unauthorized");
	const roles = getRolesFromSession(session!);

	const statusResponse = await waitlistStatus({
		...apiClientOptions(cookies),
		throwOnError: true,
	});

	return {
		canToggleWaitlist: roles.intersection(allowedToggleRoles).size > 0,
		isWaitlistOpen: statusResponse.data.data.isOpen,
	};
};
