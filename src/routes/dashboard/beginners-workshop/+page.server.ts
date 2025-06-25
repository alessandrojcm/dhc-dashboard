import { error } from '@sveltejs/kit';
import * as Sentry from '@sentry/sveltekit';

import type { PageServerLoad } from './$types';
import { getKyselyClient, executeWithRLS } from '$lib/server/kysely';
import { invariant } from '$lib/server/invariant';
import { sql } from 'kysely';
import { allowedToggleRoles, getRolesFromSession } from '$lib/server/roles';

export const load: PageServerLoad = async ({ locals, platform, depends }) => {
	const { session } = await locals.safeGetSession();

	depends("waitlist:status");

	invariant(session === null, 'User not authenticated');
	invariant(platform?.env.HYPERDRIVE === undefined, 'HYPERDRIVE environment variable not set');

	const db = getKyselyClient(platform!.env.HYPERDRIVE);

	const workshops = await executeWithRLS(db, { claims: session! }, (trx) =>
		trx
			.selectFrom('workshops')
			.leftJoin('user_profiles as coach', 'coach.id', 'workshops.coach_id')
			.select((eb) => [
				'workshops.id',
				'workshops.workshop_date',
				'workshops.location',
				'workshops.status',
				'workshops.capacity',
				eb.fn('concat', [eb.ref('coach.first_name'), sql`' '::text`, eb.ref('coach.last_name')]).as('coach')
			])
			.orderBy('workshops.created_at', 'desc')
			.execute()
	).catch((e) => {
		Sentry.captureException(e);
		error(500, 'Error fetching workshops: ' + e.message);
	});

	const roles = getRolesFromSession(session!);

	return {
		workshops: workshops ?? [], 
		canToggleWaitlist: roles.intersection(allowedToggleRoles).size > 0,
		isWaitlistOpen: locals.supabase
			.from("settings")
			.select("value")
			.eq("key", "waitlist_open")
			.single()
			.then((result) => result.data?.value === "true"),
	};
};