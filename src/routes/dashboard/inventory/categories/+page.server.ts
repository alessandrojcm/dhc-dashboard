import { authorize } from '$lib/server/auth';
import { INVENTORY_ROLES } from '$lib/server/roles';

export const load = async ({ locals }: { locals: App.Locals }) => {
	await authorize(locals, INVENTORY_ROLES);
};
