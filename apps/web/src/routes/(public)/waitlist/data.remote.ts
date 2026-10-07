import { form } from "$app/server";
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
 *
 * Phoenix answers an email that is already on the waitlist exactly like a new
 * entry (the public endpoint must not reveal who is on it), so there is no
 * duplicate-email branch here: both show the same success message.
 */
export const submitWaitlist = form(beginnersWaitlistSchema, async (data) => {
	let response;
	try {
		response = await waitlistCreateEntry({
			baseUrl: apiBaseUrl(),
			body: data satisfies WaitlistEntryCreateRequest,
		});
	} catch (err) {
		console.error("Waitlist submission error:", err);
		throw new Error("Something went wrong, please try again later.");
	}

	if (response.error) {
		console.error("Waitlist submission error:", apiErrorDetail(response.error));
		throw new Error("Something went wrong, please try again later.");
	}

	return {
		success: "You have been added to the waitlist, we will be in contact soon!",
	};
});
