import { invariant } from './invariant';
import { getRolesFromSession } from './roles';

export async function authorize(locals: App.Locals, allowedRoles: Set<string>) {
	const { session } = await locals.safeGetSession();
	invariant(!session, 'Unauthorized');

	const roles = getRolesFromSession(session!);
	const hasPermission = roles.intersection(allowedRoles).size > 0;
	invariant(!hasPermission, 'Unauthorized', 403);

	return session!;
}
