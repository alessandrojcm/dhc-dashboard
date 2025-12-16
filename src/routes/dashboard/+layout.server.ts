import { filterNavByRoles, navData } from '$lib/server/rbacRoles';
import type { LayoutServerLoad } from './$types';
import { invariant } from '$lib/server/invariant';

export const load: LayoutServerLoad = async ({ locals: { supabase } }) => {
	const userId = await supabase.auth.getUser().then((u) => u.data.user?.id);
	invariant(userId === undefined, 'Unauthorized')

	const roles = await supabase
		.from('user_roles')
		.select('role')
		.eq('user_id', userId!);

	const userRoles = roles.data!.map((r) => r.role)!;
	return {
		roles: userRoles,
		navData: filterNavByRoles(navData, userRoles)
	};
};
