import type { LayoutServerLoad } from "./$types";
import { getPhoenixSession } from "#lib/server/auth.js";

export const load: LayoutServerLoad = async ({ locals, cookies }) => {
	// null is an authoritative signed-out result from the hook, not a cache miss.
	const session =
		locals.session !== undefined
			? locals.session
			: await getPhoenixSession(cookies);
	return {
		session,
		cookies: cookies.getAll(),
	};
};
