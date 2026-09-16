import { waitlistStatus } from "@dhc/api-client";
import { apiClientOptions } from "$lib/server/api-client";
import { authorizationFor } from "$lib/server/authorization";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, cookies, depends }) => {
	depends("wailist:status");
	const { session } = await locals.safeGetSession();
	const access = authorizationFor(session);
	access.require("beginners.workshop.read");

	const statusResponse = await waitlistStatus({
		...apiClientOptions(cookies),
		throwOnError: true,
	});

	return {
		canToggleWaitlist: access.can("beginners.waitlist.toggle"),
		isWaitlistOpen: statusResponse.data.data.isOpen,
	};
};
