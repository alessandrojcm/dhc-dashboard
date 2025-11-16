import { filterNavByRoles, navData } from "$lib/server/rbacRoles";
import type { LayoutServerLoad } from "./$types";

export const load: LayoutServerLoad = async ({ locals: { supabase } }) => {
	const roles = await supabase
		.from("user_roles")
		.select("role")
		.eq("user_id", await supabase.auth.getUser().then((u) => u.data.user?.id));

	const userRoles = roles.data?.map((r) => r.role);
	return {
		roles: userRoles,
		navData: filterNavByRoles(navData, userRoles),
	};
};
