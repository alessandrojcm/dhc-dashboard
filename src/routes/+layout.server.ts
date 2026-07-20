import type { LayoutServerLoad } from "./$types";
import { getPhoenixSession } from "$lib/server/auth";

export const load: LayoutServerLoad = async ({ locals, cookies }) => {
	const session = locals.session ?? (await getPhoenixSession(cookies));
	return {
		session,
		cookies: cookies.getAll(),
	};
};
