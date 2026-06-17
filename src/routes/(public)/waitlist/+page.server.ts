import { error } from "@sveltejs/kit";
import { waitlistStatus } from "@dhc/api-client";
import { apiBaseUrl } from "$lib/server/api-client";
import { supabaseServiceClient } from "$lib/server/supabaseServiceClient";
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

	return {
		genders: await supabaseServiceClient
			.rpc("get_gender_options")
			.then((res) => (res.data ?? []) as string[]),
	};
};
