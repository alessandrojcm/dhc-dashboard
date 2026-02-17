import { error } from "@sveltejs/kit";
import { supabaseServiceClient } from "$lib/server/supabaseServiceClient";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async () => {
	const isWaitlistOpen = await supabaseServiceClient
		.from("settings")
		.select("value")
		.eq("key", "waitlist_open")
		.single()
		.throwOnError()
		.then((result) => result?.data?.value === "true");

	if (!isWaitlistOpen) {
		error(401, "The waitlist is currently closed, please come back later.");
	}

	return {
		genders: await supabaseServiceClient
			.rpc("get_gender_options")
			.then((res) => (res.data ?? []) as string[]),
	};
};
