import { authorizationFor } from "#lib/server/authorization/index.js";
import type { PageServerLoad } from "./$types";

// The composer, live preview and history all talk to Phoenix from the
// browser through the typed client (ADR 0028).
export const ssr = false;

export const load: PageServerLoad = ({ locals }) => {
	authorizationFor(locals.session).require("member_announcements.send");
};
