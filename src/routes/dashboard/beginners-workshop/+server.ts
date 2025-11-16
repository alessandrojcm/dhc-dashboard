import * as Sentry from "@sentry/sveltekit";
import { json } from "@sveltejs/kit";
import { invariant } from "$lib/server/invariant";
import { executeWithRLS, getKyselyClient } from "$lib/server/kysely";
import { allowedToggleRoles, getRolesFromSession } from "$lib/server/roles";
import type { RequestHandler } from "./$types";

export const POST: RequestHandler = async ({ locals, platform }) => {
	try {
		const { session } = await locals.safeGetSession();
		invariant(session === null, "Unauthorized");
		const roles = getRolesFromSession(session!);
		const canToggleWaitlist = roles.intersection(allowedToggleRoles).size > 0;

		if (!canToggleWaitlist) {
			return json({ success: false }, { status: 403 });
		}
		const kysely = getKyselyClient(platform?.env.HYPERDRIVE);
		const currentValue = await kysely
			.selectFrom("settings")
			.select("value")
			.where("key", "=", "waitlist_open")
			.executeTakeFirstOrThrow();

		const newValue = currentValue.value === "true" ? "false" : "true";

		await executeWithRLS(
			kysely,
			{
				claims: session!,
			},
			async (trx) => {
				await trx
					.updateTable("settings")
					.set({ value: newValue })
					.where("key", "=", "waitlist_open")
					.execute();
			},
		);

		return json({ success: true });
	} catch (error) {
		Sentry.captureMessage(`Error toggling waitlist: ${error}}`, "error");
		return json(
			{ success: false, error: "Internal server error" },
			{ status: 500 },
		);
	}
};
