import * as Sentry from "@sentry/sveltekit";
import { waitlistUpdateStatus } from "@dhc/api-client";
import { json } from "@sveltejs/kit";
import { apiClientOptions } from "$lib/server/api-client";
import { invariant } from "$lib/server/invariant";
import { allowedToggleRoles, getRolesFromSession } from "$lib/server/roles";
import type { RequestHandler } from "./$types";

export const POST: RequestHandler = async ({ locals, request }) => {
	try {
		const { session } = await locals.safeGetSession();
		invariant(session === null, "Unauthorized");
		const body = (await request.json()) as { isOpen?: unknown };
		if (typeof body.isOpen !== "boolean") {
			return json({ success: false, error: "Invalid waitlist status" }, { status: 400 });
		}
		const roles = getRolesFromSession(session!);
		const canToggleWaitlist = roles.intersection(allowedToggleRoles).size > 0;

		if (!canToggleWaitlist) {
			return json({ success: false }, { status: 403 });
		}

		const response = await waitlistUpdateStatus({
			...apiClientOptions(session!),
			body: { isOpen: body.isOpen },
		});

		if (response.error) {
			throw new Error("Failed to update waitlist status");
		}

		return json({ success: true });
	} catch (error) {
		Sentry.captureMessage(`Error toggling waitlist: ${error}`, "error");
		return json(
			{ success: false, error: "Internal server error" },
			{ status: 500 },
		);
	}
};
