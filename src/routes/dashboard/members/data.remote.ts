import { form, getRequestEvent } from '$app/server';
import { InsuranceFormLinkSchema, createSettingsService } from '$lib/server/services/settings';
import { invariant } from '$lib/server/invariant';
import { getRolesFromSession, SETTINGS_ROLES } from '$lib/server/roles';

export const updateMemberSettings = form(InsuranceFormLinkSchema, async (data) => {
	const event = getRequestEvent();
	const { session } = await event.locals.safeGetSession();

	invariant(session === null, 'Unauthorized');
	const roles = getRolesFromSession(session!);
	invariant(roles.intersection(SETTINGS_ROLES).size === 0, 'Unauthorized', 403);

	const settingsService = createSettingsService(event.platform!, session!);
	await settingsService.updateInsuranceFormLink(data.insuranceFormLink);

	return { success: 'Settings updated successfully' };
});
