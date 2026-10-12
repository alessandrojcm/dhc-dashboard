import { error } from "@sveltejs/kit";
import { beginnersWorkshopDoorShow } from "@dhc/api-client";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorizationFor } from "#lib/server/authorization/index.js";
import type { PageServerLoad } from "./$types";

/**
 * ALE-379: a workshop's door view. Every member reaches the route; Phoenix
 * decides `beginners.workshops.run` against the workshop's Staff and answers
 * 404 for anyone else, which this page passes on unchanged.
 */
export const load: PageServerLoad = async ({ locals, cookies, params }) => {
	const { session } = await locals.safeGetSession();
	const access = authorizationFor(session);
	access.require("beginners.workshops.assigned.read");

	const {
		data,
		error: apiError,
		response,
	} = await beginnersWorkshopDoorShow({
		...apiClientOptions(cookies),
		path: { id: params.workshopId },
	});

	if (apiError) {
		if (response?.status === 404) error(404, "Beginners' Workshop not found");
		error(503, "Unable to load the workshop");
	}

	return {
		workshop: data.data,
		canManageWorkshops: access.can("beginners.workshops.manage"),
	};
};
