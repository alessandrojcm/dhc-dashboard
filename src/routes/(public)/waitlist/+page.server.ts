import { error } from "@sveltejs/kit";
import { membersOptions, waitlistStatus } from "@dhc/api-client";
import { apiBaseUrl } from "$lib/server/api-client";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async () => {
	const { data, error: statusError } = await waitlistStatus({
		baseUrl: apiBaseUrl(),
	});

	if (statusError) {
		error(503, "Unable to check waitlist status, please try again later.");
	}

	const isWaitlistOpen = data?.data.isOpen;

	if (!isWaitlistOpen) {
		error(401, "The waitlist is currently closed, please come back later.");
	}

	const { data: options, error: optionsError } = await membersOptions({
		baseUrl: apiBaseUrl(),
	});

	if (optionsError) {
		error(503, "Unable to load waitlist options, please try again later.");
	}

	return { genders: options?.data.genders ?? [] };
};
