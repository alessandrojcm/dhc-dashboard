import { getRolesFromSession, allowedToggleRoles } from '$lib/server/roles';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, depends }) => {
	depends('wailist:status');
	return {
		canToggleWaitlist:
			getRolesFromSession(locals.session!).intersection(allowedToggleRoles).size > 0,
		isWaitlistOpen: locals.supabase
			.from('settings')
			.select('value')
			.eq('key', 'waitlist_open')
			.single()
			.then((result) => result.data?.value === 'true')
	};
};