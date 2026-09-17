import { authorizationFor } from "$lib/server/authorization";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = ({ locals }) => {
	authorizationFor(locals.session).require("members.directory.read");
};
