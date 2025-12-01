import { invariant } from '$lib/server/invariant';
import { allowedToggleRoles, getRolesFromSession } from '$lib/server/roles';
import { createSettingsService } from '$lib/server/services/settings';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, depends, platform }) => {
	depends('wailist:status');
	const { session } = await locals.safeGetSession();
	invariant(session === null, 'Unauthorized');
	const roles = getRolesFromSession(session!);

	const settingsService = createSettingsService(platform!, session!);

	return {
		canToggleWaitlist: roles.intersection(allowedToggleRoles).size > 0,
		isWaitlistOpen: settingsService.isWaitlistOpen()
	};
};
