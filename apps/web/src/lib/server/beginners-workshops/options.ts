import { getRequestEvent } from "$app/server";
import { apiClientOptions } from "#lib/server/api-client.js";
import { authorize } from "#lib/server/auth.js";
import type { Capability } from "#lib/server/authorization/index.js";

/**
 * Generated-client options for a Beginners' Workshop command, after checking
 * `capability`. Phoenix checks it again; this only keeps the dashboard from
 * calling it for nobody.
 */
async function commandOptions(capability: Capability) {
	const event = getRequestEvent();
	await authorize(event.locals, capability);
	return apiClientOptions(event.cookies);
}

/** A Beginners' Workshop management command (`beginners.workshops.manage`). */
export const beginnersWorkshopsManageOptions = () =>
	commandOptions("beginners.workshops.manage");

/** ALE-387: `withdraw`, the Waitlist's own exit (`beginners.waitlist.manage`). */
export const beginnersWaitlistManageOptions = () =>
	commandOptions("beginners.waitlist.manage");

/** ALE-392: the Invitation handoff (`members.invite`). */
export const membersInviteOptions = () => commandOptions("members.invite");
