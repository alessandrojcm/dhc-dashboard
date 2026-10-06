import { form } from "$app/server";
import { invalid } from "@sveltejs/kit";
import {
	waitlistCreateEntry,
	type WaitlistEntryCreateRequest,
} from "@dhc/api-client";
import beginnersWaitlistSchema from "#lib/schemas/beginnersWaitlist.js";
import { apiBaseUrl } from "#lib/server/api-client.js";
import { apiErrorDetail } from "#lib/api-error.js";

/**
 * Waitlist submission form. The schema's output is the Phoenix request body,
 * so the validated data is sent unchanged.
 */
export const submitWaitlist = form(
	beginnersWaitlistSchema,
	async (data, issue) => {
		let response;
		try {
			response = await waitlistCreateEntry({
				baseUrl: apiBaseUrl(),
				body: data satisfies WaitlistEntryCreateRequest,
			});
		} catch (err) {
			console.error("Waitlist submission error:", err);

			if (err instanceof Error && err.message.includes("duplicate")) {
				invalid(issue.email("This email is already on the waitlist"));
			}

			throw new Error("Something went wrong, please try again later.");
		}

		if (response.error) {
			const detail = apiErrorDetail(response.error);

			if (detail?.includes("already on the waitlist")) {
				invalid(issue.email("This email is already on the waitlist"));
			}

			console.error("Waitlist submission error:", detail);
			throw new Error("Something went wrong, please try again later.");
		}

		return {
			success:
				"You have been added to the waitlist, we will be in contact soon!",
		};
	},
);
