import { error, fail } from "@sveltejs/kit";
import { message, superValidate } from "sveltekit-superforms";
import { valibot } from "sveltekit-superforms/adapters";
import beginnersWaitlist, {
	calculateAge,
} from "$lib/schemas/beginnersWaitlist";
import { getKyselyClient } from "$lib/server/kysely";
import { insertWaitlistEntry } from "$lib/server/kyselyRPCFunctions";
import { supabaseServiceClient } from "$lib/server/supabaseServiceClient";
import type { Actions, PageServerLoad } from "./$types";

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
		form: await superValidate(valibot(beginnersWaitlist)),
		genders: await supabaseServiceClient
			.rpc("get_gender_options")
			.then((res) => (res.data ?? []) as string[]),
	};
};

export const actions: Actions = {
	default: async (event) => {
		const form = await superValidate(event, valibot(beginnersWaitlist));
		if (!form.valid) {
			return fail(422, {
				form,
			});
		}
		const formData = form.data;
		const age = calculateAge(formData.dateOfBirth);
		try {
			const kysely = getKyselyClient(event.platform?.env.HYPERDRIVE);
			await kysely.transaction().execute(async (trx) => {
				// 1. call existing function and capture the waitlist row
				const results = await insertWaitlistEntry(formData, trx);
				const profileId = results.profile_id;
				if (
					[
						formData.guardianFirstName,
						formData.guardianLastName,
						formData.guardianPhoneNumber,
						age < 18,
					].every(Boolean)
				) {
					// 2. insert guardian row
					await trx
						.insertInto("waitlist_guardians")
						.values({
							profile_id: profileId,
							first_name: formData.firstName!,
							last_name: formData.lastName!,
							phone_number: formData.phoneNumber!,
						})
						.execute();
				}
			});
		} catch (err) {
			console.error(err);
			return message(
				form,
				{ error: "Something has gone wrong, please try again later." },
				{ status: 500 },
			);
		}
		return message(form, {
			success:
				"You have been added to the waitlist, we will be in contact soon!",
		});
	},
};
