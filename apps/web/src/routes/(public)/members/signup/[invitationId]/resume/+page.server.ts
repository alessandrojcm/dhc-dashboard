import { redirect } from "@sveltejs/kit";
import type { PageServerLoad } from "./$types";

// The resume URL contains only the public invitation route parameter. The
// protected continuation remains in the HTTP-only cookie scoped to its parent.
export const load: PageServerLoad = async ({ params }) => {
	throw redirect(303, `/members/signup/${params.invitationId}`);
};
