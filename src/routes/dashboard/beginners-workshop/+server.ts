import * as Sentry from "@sentry/sveltekit";
import { json } from "@sveltejs/kit";
import { invariant } from "$lib/server/invariant";
import { allowedToggleRoles, getRolesFromSession } from "$lib/server/roles";
import { createSettingsService } from "$lib/server/services/settings";
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

		const settingsService = createSettingsService(platform!, session!);
		await settingsService.toggleWaitlist();

		return json({ success: true });
	} catch (error) {
		Sentry.captureMessage(`Error toggling waitlist: ${error}`, "error");
		return json(
			{ success: false, error: "Internal server error" },
			{ status: 500 },
		);
	}
};
