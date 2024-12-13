import { getRolesFromSession } from '$lib/server/getRolesFromSession';
import type { PageServerLoad } from './$types';

const allowedToggleRoles = new Set(['president', 'admin', 'committee_coordinator']);
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
