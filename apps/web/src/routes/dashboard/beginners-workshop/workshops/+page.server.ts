import {
	beginnersWorkshopsList,
	beginnersWorkshopsStaffCandidates,
} from "@dhc/api-client";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorizationFor } from "#lib/server/authorization/index.js";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, cookies }) => {
	const { session } = await locals.safeGetSession();
	authorizationFor(session).require("beginners.workshops.manage");
	const [workshops, staffCandidates] = await Promise.all([
		beginnersWorkshopsList({
			...apiClientOptions(cookies),
			throwOnError: true,
		}).then((response) => response.data.data),
		beginnersWorkshopsStaffCandidates({
			...apiClientOptions(cookies),
			throwOnError: true,
		}).then((response) => response.data.data),
	]);
	return { workshops, staffCandidates };
};
