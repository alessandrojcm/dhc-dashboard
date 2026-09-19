import { authorizationFor } from "$lib/server/authorization";
import type { PageServerLoad } from "./$types";

export const ssr = false;

export const load: PageServerLoad = ({ locals }) => {
	authorizationFor(locals.session).require("workshops.own.read");
};
