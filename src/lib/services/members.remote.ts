import * as v from "valibot";
import { command, getRequestEvent } from "$app/server";

import { invariant } from "$lib/server/invariant";
import { getKyselyClient } from "$lib/server/kysely";
import { getRolesFromSession, SETTINGS_ROLES } from "$lib/server/roles";

export const deleteInvitations = command(
	v.array(v.pipe(v.string(), v.uuid())),
	async (ids) => {
		const event = getRequestEvent();
		const { session } = await event.locals.safeGetSession();
		invariant(session === null, "Unauthorized");
		const roles = getRolesFromSession(session!);
		const canEditSettings = roles.intersection(SETTINGS_ROLES).size > 0;
		invariant(!canEditSettings, "Unauthorized", 403);
		const kysely = getKyselyClient(event.platform?.env?.HYPERDRIVE);

		await kysely.transaction().execute(async (trx) => {
			const uIds = await trx
				.deleteFrom("invitations")
				.where("invitations.id", "in", ids)
				.returningAll()
				.execute();

			return Promise.all([
				trx
					.deleteFrom("user_profiles")
					.where(
						"user_profiles.supabase_user_id",
						"in",
						uIds.map((u) => u.user_id),
					)
					.execute(),
				...uIds
					.map((u) => u.waitlist_id)
					.filter(Boolean)
					.map((w) =>
						trx.deleteFrom("waitlist").where("waitlist.id", "=", w).execute(),
					),
				...uIds.map((u) =>
					event.locals.supabase.auth.admin.deleteUser(u.user_id!),
				),
			]);
		});
	},
);
