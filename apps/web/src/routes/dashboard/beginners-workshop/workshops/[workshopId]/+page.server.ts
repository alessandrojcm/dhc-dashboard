import { error } from "@sveltejs/kit";
import { beginnersWorkshopsConsole } from "@dhc/api-client";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorizationFor } from "#lib/server/authorization/index.js";
import type { PageServerLoad } from "./$types";

// ALE-380: one workshop's console — Phoenix's read model, displayed as is.
export const load: PageServerLoad = async ({ locals, cookies, params }) => {
	const { session } = await locals.safeGetSession();
	authorizationFor(session).require("beginners.workshops.manage");

	const response = await beginnersWorkshopsConsole({
		...apiClientOptions(cookies),
		path: { id: params.workshopId },
	});

	if (!response.data) {
		if (response.response?.status === 404)
			error(404, "Beginners' Workshop not found");
		error(502, "Could not load the workshop console");
	}

	return { console: response.data.data };
};
