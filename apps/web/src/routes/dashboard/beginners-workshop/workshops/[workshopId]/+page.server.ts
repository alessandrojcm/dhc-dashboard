import { error } from "@sveltejs/kit";
import { beginnersWorkshopsConsole, membersOptions } from "@dhc/api-client";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorizationFor } from "#lib/server/authorization/index.js";
import type { PageServerLoad } from "./$types";

// ALE-380: one workshop's console — Phoenix's read model, displayed as is.
export const load: PageServerLoad = async ({ locals, cookies, params }) => {
	const { session } = await locals.safeGetSession();
	const access = authorizationFor(session);
	access.require("beginners.workshops.manage");

	// The genders feed the Fast-track dialog's "add a new person" form.
	const [response, options] = await Promise.all([
		beginnersWorkshopsConsole({
			...apiClientOptions(cookies),
			path: { id: params.workshopId },
		}),
		membersOptions(apiClientOptions(cookies)),
	]);

	if (!response.data) {
		if (response.response?.status === 404)
			error(404, "Beginners' Workshop not found");
		error(502, "Could not load the workshop console");
	}

	return {
		console: response.data.data,
		genders: options.data?.data.genders ?? [],
		// ALE-392: who may send attended people their Invitation.
		canInvite: access.can("members.invite"),
	};
};
