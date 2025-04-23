import { allowedToggleRoles, getRolesFromSession } from "$lib/server/roles";
import type { PageServerLoad } from "./$types";
import { invariant } from "$lib/server/invariant";

export const load: PageServerLoad = async ({ locals, depends }) => {
	depends("wailist:status");
	const { session } = await locals.safeGetSession();
	invariant(session === null, "Unauthorized");
	const roles = getRolesFromSession(session!);
	return {
		canToggleWaitlist: roles.intersection(allowedToggleRoles).size > 0,
		isWaitlistOpen: locals.supabase
			.from("settings")
			.select("value")
			.eq("key", "waitlist_open")
			.single()
			.then((result) => result.data?.value === "true"),
	};
};
