import { authorize } from '$lib/server/auth';
import { getRolesFromSession, INVENTORY_READ_ROLES, INVENTORY_ROLES } from '$lib/server/roles';
import type { LayoutServerLoad } from './$types';

export const load: LayoutServerLoad = async (event) => {
	const session = await authorize(event.locals, INVENTORY_READ_ROLES);
	return {
		canEdit: getRolesFromSession(session).intersection(INVENTORY_ROLES).size > 0
	};
};
