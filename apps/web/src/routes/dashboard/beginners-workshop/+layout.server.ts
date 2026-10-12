import { waitlistStatus } from "@dhc/api-client";
import { isBeginnersWorkshopSection } from "#lib/beginners-workshops/sections.js";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorizationFor } from "#lib/server/authorization/index.js";
import type { LayoutServerLoad } from "./$types";

export const load: LayoutServerLoad = async ({
	locals,
	cookies,
	depends,
	route,
}) => {
	const { session } = await locals.safeGetSession();
	const access = authorizationFor(session);
	const isSection = isBeginnersWorkshopSection(route.id);
	// Door and console pages own their resource checks; assigned Staff may not manage the Waitlist.
	if (isSection) access.require("beginners.waitlist.manage");
	let isWaitlistOpen: boolean | null = null;
	if (isSection) {
		depends("wailist:status");
		const response = await waitlistStatus({
			...apiClientOptions(cookies),
			throwOnError: true,
		});
		isWaitlistOpen = response.data.data.isOpen;
	}
	return {
		canToggleWaitlist: access.can("beginners.waitlist.toggle"),
		canManageWorkshops: access.can("beginners.workshops.manage"),
		canInvite: access.can("members.invite"),
		isWaitlistOpen,
	};
};
