import { error } from '@sveltejs/kit';
import * as Sentry from '@sentry/sveltekit';

import type { PageServerLoad } from './$types';
import { invariant } from '$lib/server/invariant';
import { allowedToggleRoles, getRolesFromSession } from '$lib/server/roles';

export const load: PageServerLoad = async ({ locals, platform, depends }) => {
	const { session } = await locals.safeGetSession();

	depends("waitlist:status");

	invariant(session === null, 'User not authenticated');
	invariant(platform?.env.HYPERDRIVE === undefined, 'HYPERDRIVE environment variable not set');

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