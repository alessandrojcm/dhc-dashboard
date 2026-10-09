import {
	beginnersWorkshopsList,
	beginnersWorkshopsStaffCandidates,
	waitlistStatus,
} from "@dhc/api-client";
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
	const [workshops, staffCandidates] = canManageWorkshops
		? await Promise.all([
				beginnersWorkshopsList({
					...apiClientOptions(cookies),
					throwOnError: true,
				}).then((response) => response.data.data),
				// ALE-379: who the Staff pickers offer.
				beginnersWorkshopsStaffCandidates({
					...apiClientOptions(cookies),
					throwOnError: true,
				}).then((response) => response.data.data),
			])
		: [null, []];

	return {
		staffCandidates,
		canToggleWaitlist: access.can("beginners.waitlist.toggle"),
		isWaitlistOpen: statusResponse.data.data.isOpen,
		canManageWorkshops,
		workshops,
	};
};
