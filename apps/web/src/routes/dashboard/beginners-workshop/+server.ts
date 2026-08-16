import * as Sentry from "@sentry/sveltekit";
import { waitlistUpdateStatus } from "@dhc/api-client";
import { json } from "@sveltejs/kit";
import { apiClientOptions } from "$lib/server/api-client";
import { allowedToggleRoles, getRolesFromSession } from "$lib/server/roles";
import type { RequestHandler } from "./$types";
import * as v from "valibot";

const ToggleWaitlistSchema = v.object({ isOpen: v.boolean() });

export const POST: RequestHandler = async ({ locals, cookies, request }) => {
	try {
		const { session } = await locals.safeGetSession();
		if (!session) {
			return json({ success: false }, { status: 401 });
		}
		const body = v.safeParse(ToggleWaitlistSchema, await request.json());
		if (!body.success) {
			return json(
				{ success: false, error: "Invalid waitlist status" },
				{ status: 400 },
			);
		}
		const roles = getRolesFromSession(session);
		const canToggleWaitlist = roles.intersection(allowedToggleRoles).size > 0;

		if (!canToggleWaitlist) {
			return json({ success: false }, { status: 403 });
		}

		const response = await waitlistUpdateStatus({
			...apiClientOptions(cookies),
			body: { isOpen: body.output.isOpen },
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
