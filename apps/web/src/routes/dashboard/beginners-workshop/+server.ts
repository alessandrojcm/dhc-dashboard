import * as Sentry from "@sentry/sveltekit";
import { waitlistUpdateStatus } from "@dhc/api-client";
import { json } from "@sveltejs/kit";
import { apiClientOptions } from "$lib/server/api-client";
import { authorizationFor } from "$lib/server/authorization";
import type { RequestHandler } from "./$types";
import * as v from "valibot";

const ToggleWaitlistSchema = v.object({ isOpen: v.boolean() });

export const POST: RequestHandler = async ({ locals, cookies, request }) => {
	try {
		// GH-510: the JSON endpoint maps the decision onto its own response
		// shape instead of throwing, so the status stays on `decide()`.
		const { session } = await locals.safeGetSession();
		const decision = authorizationFor(session).decide(
			"beginners.waitlist.toggle",
		);
		if (!decision.allowed && decision.status === 401) {
			return json({ success: false }, { status: 401 });
		}
		const body = v.safeParse(ToggleWaitlistSchema, await request.json());
		if (!body.success) {
			return json(
				{ success: false, error: "Invalid waitlist status" },
				{ status: 400 },
			);
		}
		if (!decision.allowed) {
			return json({ success: false }, { status: decision.status });
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
