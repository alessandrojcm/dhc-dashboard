import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import type { PageServerLoad } from './$types';

export const ssr = false;

export const load: PageServerLoad = async ({ locals }) => {
	await authorize(locals, WORKSHOP_ROLES);

	return {};
};
