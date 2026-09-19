import { authorize } from "$lib/server/auth";
import type { PageServerLoad } from "./$types";

export const ssr = false;

export const load: PageServerLoad = async ({ locals }) => {
	const session = await authorize(locals, "workshops.manage");

	// ALE-164: the calendar component needs the signed-in principal id to
	// highlight the current user's workshops. Previously sourced from the
	// Supabase `user.id`; now from the Phoenix session projection.
	return { user: { id: session.principal.id } };
};
