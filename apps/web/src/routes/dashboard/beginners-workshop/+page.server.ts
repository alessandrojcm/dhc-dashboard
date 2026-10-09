import { beginnersWorkshopsList, waitlistStatus } from "@dhc/api-client";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorizationFor } from "#lib/server/authorization/index.js";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, cookies, depends }) => {
	depends("wailist:status");
	const { session } = await locals.safeGetSession();
	const access = authorizationFor(session);
	access.require("beginners.waitlist.manage");

	const statusResponse = await waitlistStatus({
		...apiClientOptions(cookies),
		throwOnError: true,
	});

	// ALE-378: the Workshops tab is the coordinator's and the officers'.
	const canManageWorkshops = access.can("beginners.workshops.manage");
	const workshops = canManageWorkshops
		? (
				await beginnersWorkshopsList({
					...apiClientOptions(cookies),
					throwOnError: true,
				})
			).data.data
		: null;

	return {
		canToggleWaitlist: access.can("beginners.waitlist.toggle"),
		isWaitlistOpen: statusResponse.data.data.isOpen,
		canManageWorkshops,
		workshops,
	};
};
