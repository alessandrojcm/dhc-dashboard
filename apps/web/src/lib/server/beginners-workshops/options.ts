import { getRequestEvent } from "$app/server";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorize } from "#lib/server/auth.js";

/**
 * Generated-client options for a Beginners' Workshop management command,
 * after checking the `beginners.workshops.manage` capability. Phoenix checks
 * it again; this only keeps the dashboard from calling it for nobody.
 */
export async function beginnersWorkshopsManageOptions() {
	const event = getRequestEvent();
	await authorize(event.locals, "beginners.workshops.manage");
	return apiClientOptions(event.cookies);
}
