<<<<<<< HEAD
import { error } from "@sveltejs/kit";
import { supabaseServiceClient } from "$lib/server/supabaseServiceClient";
import type { PageServerLoad } from "./$types";
=======
import { error } from '@sveltejs/kit';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import type { PageServerLoad } from './$types';
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)

export const load: PageServerLoad = async () => {
	const isWaitlistOpen = await supabaseServiceClient
		.from("settings")
		.select("value")
		.eq("key", "waitlist_open")
		.single()
		.throwOnError()
<<<<<<< HEAD
		.then((result) => result?.data?.value === "true");
=======
		.then((result) => result?.data?.value === 'true');
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)

	if (!isWaitlistOpen) {
		error(401, "The waitlist is currently closed, please come back later.");
	}

	return {
		genders: await supabaseServiceClient
			.rpc("get_gender_options")
			.then((res) => (res.data ?? []) as string[]),
	};
};
