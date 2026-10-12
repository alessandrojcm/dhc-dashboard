import { beginnersWorkshopInvitationsInvitable } from "@dhc/api-client";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorizationFor } from "#lib/server/authorization/index.js";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, cookies }) => {
	const { session } = await locals.safeGetSession();
	authorizationFor(session).require("members.invite");
	const response = await beginnersWorkshopInvitationsInvitable({
		...apiClientOptions(cookies),
		throwOnError: true,
	});
	return { invitable: response.data.data };
};
