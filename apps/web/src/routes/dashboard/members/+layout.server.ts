import { membersInsuranceForm } from "@dhc/api-client";
import { apiClientOptions } from "$lib/server/api-client";
import { invariant } from "$lib/server/invariant";
import { getRolesFromSession, SETTINGS_ROLES } from "$lib/server/roles";
import type { LayoutServerLoad } from "./$types";

export const load: LayoutServerLoad = async ({ locals, cookies }) => {
	const { session } = await locals.safeGetSession();
	invariant(session === null, "Unauthorized");
	const roles = getRolesFromSession(session!);
	const canEditSettings = roles.intersection(SETTINGS_ROLES).size > 0;

	if (!canEditSettings) {
		return { canEditSettings, membersInsuranceFormLink: "" };
	}

	const insuranceFormResponse = await membersInsuranceForm({
		...apiClientOptions(cookies),
		throwOnError: true,
	});

	return {
		canEditSettings,
		membersInsuranceFormLink: insuranceFormResponse.data.data.link ?? "",
	};
};
