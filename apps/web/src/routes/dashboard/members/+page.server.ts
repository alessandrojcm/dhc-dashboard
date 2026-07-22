import { membersInsuranceForm } from "@dhc/api-client";
import { invariant } from "$lib/server/invariant";
import { getRolesFromSession, SETTINGS_ROLES } from "$lib/server/roles";
import { apiClientOptions } from "$lib/server/api-client";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, cookies }) => {
	const { session } = await locals.safeGetSession();
	invariant(session === null, "Unauthorized");
	const roles = getRolesFromSession(session!);
	const canEditSettings = roles.intersection(SETTINGS_ROLES).size > 0;

	const insuranceFormResponse = await membersInsuranceForm({
		...apiClientOptions(cookies),
		throwOnError: true,
	});

	return {
		canEditSettings,
		insuranceFormLink: canEditSettings
			? (insuranceFormResponse.data.data.link ?? "")
			: "",
	};
};
