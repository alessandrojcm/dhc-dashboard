import { invariant } from "$lib/server/invariant";
import { getRolesFromSession, SETTINGS_ROLES } from "$lib/server/roles";
import { createSettingsService } from "$lib/server/services/settings";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ locals, platform }) => {
	const { session } = await locals.safeGetSession();
	invariant(session === null, "Unauthorized");
	const roles = getRolesFromSession(session!);
	const canEditSettings = roles.intersection(SETTINGS_ROLES).size > 0;

	// Use SettingsService to fetch insurance form link
	const settingsService = createSettingsService(platform!, session!);
	const insuranceLinkSetting = await settingsService.findByKey(
		"hema_insurance_form_link",
	);

	return {
		canEditSettings,
		insuranceFormLink:
			canEditSettings && insuranceLinkSetting ? insuranceLinkSetting.value : "",
	};
};
