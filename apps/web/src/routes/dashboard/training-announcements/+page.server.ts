import { authorizationFor } from "$lib/server/authorization";
import { dublinToday } from "$lib/training-announcements/announcement";
import type { PageServerLoad } from "./$types";

// The list is read in the browser through the typed client, like every other
// operator dashboard page.
export const ssr = false;

export const load: PageServerLoad = ({ locals }) => {
	// GH-510: the same capability as the "Training Announcements" navigation
	// entry and the request hook; here it surfaces as a 403 rather than the
	// hook's redirect.
	authorizationFor(locals.session).require("training_announcements.manage");

	// Announcements are scheduled in Europe/Dublin civil time, so the sheet's
	// default dates must come from the club's day, not the reader's.
	return { today: dublinToday() };
};
