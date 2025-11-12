import type { LayoutServerLoad } from './$types';
import { getRolesFromSession, INVENTORY_READ_ROLES, INVENTORY_ROLES } from '$lib/server/roles';
import { authorize } from '$lib/server/auth';

export const load: LayoutServerLoad = async (event) => {
	const session = await authorize(event.locals, INVENTORY_READ_ROLES);
	return {
		canEdit: getRolesFromSession(session).intersection(INVENTORY_ROLES).size > 0
	};
};
