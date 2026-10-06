import { authorizationFor } from "#lib/server/authorization/index.js";
import type { PageServerLoad } from "./$types";

export const ssr = false;

export const load: PageServerLoad = ({ locals }) => {
	authorizationFor(locals.session).require("inventory.catalog.read");
};
