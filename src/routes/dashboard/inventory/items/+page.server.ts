import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';
import { getKyselyClient, executeWithRLS } from '$lib/server/kysely';

export const load = async ({
	locals,
	platform
}: {
	locals: App.Locals;
	platform: App.Platform;
}) => {
	await authorize(locals, INVENTORY_ROLES);

	const db = getKyselyClient(platform.env!.HYPERDRIVE!);
	const { session } = await locals.safeGetSession();

	if (!session) {
		throw new Error('No session found');
	}

	// Load filter options only - actual data fetching happens client-side
	const [categories, containers] = await executeWithRLS(db, { claims: session }, async (trx) => {
		return Promise.all([
			// Load categories for filters
			trx.selectFrom('equipment_categories').select(['id', 'name']).orderBy('name').execute(),
			// Load containers for filters
			trx.selectFrom('containers').select(['id', 'name']).orderBy('name').execute()
		]);
	});

	return {
		categories: categories || [],
		containers: containers || []
	};
};
