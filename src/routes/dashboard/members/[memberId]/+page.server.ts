import type { Database } from "$database";
import signupSchema from "$lib/schemas/membersSignup";
import {
	getMemberData,
	updateMemberData,
} from "$lib/server/kyselyRPCFunctions";
import { getRolesFromSession, SETTINGS_ROLES } from "$lib/server/roles";
import { stripeClient } from "$lib/server/stripe";
import { supabaseServiceClient } from "$lib/server/supabaseServiceClient";
import { type Actions, error, type ServerLoadEvent } from "@sveltejs/kit";
import { fail, message, setMessage, superValidate } from "sveltekit-superforms";
import { valibot } from "sveltekit-superforms/adapters";
import type { RequestEvent } from "../$types";
import type { PageServerLoad } from "./$types";
import type { SocialMediaConsent } from "$lib/types.ts";
import { getKyselyClient } from "$lib/server/kysely";
import * as Sentry from "@sentry/sveltekit";
import { invariant } from "$lib/server/invariant";

async function canUpdateSettings(event: RequestEvent | ServerLoadEvent) {
	const { session } = await event.locals.safeGetSession();
	invariant(session === null, "Unauthorized");
	const roles = getRolesFromSession(session!);
	if (roles.intersection(SETTINGS_ROLES).size > 0) {
		return true;
	}
	const {
		data: { user },
		error,
	} = await event.locals.supabase.auth.getUser();

	if (error || user?.id !== event.locals.session?.user.id) {
		return false;
	}
	return true;
}

export const load: PageServerLoad = async (event) => {
	const { params, locals } = event;
	const kysely = getKyselyClient(event.platform.env.HYPERDRIVE);
	try {
		const isAdmin = await canUpdateSettings(event);
		const memberProfile = await getMemberData(params.memberId, kysely);
		if (
			!isAdmin &&
			(!memberProfile || params.memberId !== locals.session?.user.id)
		) {
			return error(404, "Member not found");
		}
		const email = await supabaseServiceClient.auth.admin.getUserById(
			params.memberId
		).then((r) => r.data.user?.email ?? '');

		return {
			form: await superValidate(
				{
					firstName: memberProfile.first_name ?? undefined,
					lastName: memberProfile.last_name ?? undefined,
					email,
					phoneNumber: memberProfile.phone_number ?? undefined,
					dateOfBirth: memberProfile.date_of_birth
						? new Date(memberProfile.date_of_birth)
						: undefined,
					pronouns: memberProfile.pronouns ?? undefined,
					gender: memberProfile.gender ?? undefined,
					medicalConditions: memberProfile.medical_conditions ??
						undefined,
					nextOfKin: memberProfile.next_of_kin_name ?? undefined,
					nextOfKinNumber: memberProfile.next_of_kin_phone ??
						undefined,
					weapon: memberProfile.preferred_weapon ?? undefined,
					insuranceFormSubmitted:
						memberProfile.insurance_form_submitted ?? undefined,
					socialMediaConsent: (memberProfile
						.social_media_consent as SocialMediaConsent) ??
						undefined,
				},
				valibot(signupSchema),
				{ errors: false },
			),
			genders: locals.supabase.rpc("get_gender_options").then((r) =>
				r.data ?? []
			) as Promise<
				string[]
			>,
			weapons: locals.supabase.rpc("get_weapons_options").then((r) =>
				r.data ?? []
			) as Promise<
				string[]
			>,
			insuranceFormLink: supabaseServiceClient
				.from("settings")
				.select("value")
				.eq("key", "insurance_form_link")
				.limit(1)
				.single()
				.then((result) => result.data?.value),
			isAdmin,
		};
	} catch (e) {
		Sentry.captureMessage(`Error loading member data: ${e}`, "error");
		error(404, {
			message: "Member not found",
		});
	}
};

export const actions: Actions = {
	"update-profile": async (event) => {
		const canUpdate = await canUpdateSettings(event as RequestEvent);
		if (!canUpdate) {
			return fail(403, { message: "Unauthorized" });
		}
		const form = await superValidate(event, valibot(signupSchema));
		if (!form.valid) {
			return fail(422, {
				form,
			});
		}
		const kysely = getKyselyClient(event.platform.env.HYPERDRIVE);
		try {
			await kysely.transaction().execute(async (trx) => {
				// Get current user data for comparison
				const currentUser = await trx
					.selectFrom("user_profiles")
					.select([
						"first_name",
						"last_name",
						"phone_number",
						"customer_id",
					])
					.where("supabase_user_id", "=", event.params.memberId!)
					.limit(1)
					.execute()
					.then((result) => result[0]);

				if (!currentUser?.customer_id) {
					throw new Error("Customer ID not found");
				}

				// Update member data
				await updateMemberData(
					{
						user_uuid: event.params.memberId!,
						p_first_name: form.data.firstName,
						p_last_name: form.data.lastName,
						p_phone_number: form.data.phoneNumber,
						p_date_of_birth: form.data.dateOfBirth.toISOString(),
						p_pronouns: form.data.pronouns,
						p_gender: form.data
							.gender as Database["public"]["Enums"]["gender"],
						p_medical_conditions: form.data.medicalConditions,
						p_next_of_kin_name: form.data.nextOfKin,
						p_next_of_kin_phone: form.data.nextOfKinNumber,
						p_preferred_weapon: form.data
							.weapon as Database["public"]["Enums"][
								"preferred_weapon"
							][],
						p_insurance_form_submitted:
							form.data.insuranceFormSubmitted,
						p_social_media_consent: form.data
							.socialMediaConsent as Database["public"]["Enums"][
								"social_media_consent"
							],
					},
					trx,
				);

				// Check if name or phone number changed
				const currentName =
					`${currentUser.first_name} ${currentUser.last_name}`.trim();
				const newName = `${form.data.firstName} ${form.data.lastName}`
					.trim();
				const nameChanged = currentName !== newName;
				const phoneChanged =
					currentUser.phone_number !== form.data.phoneNumber;

				// Only update Stripe if necessary
				if (nameChanged || phoneChanged) {
					await stripeClient.customers.update(
						currentUser.customer_id,
						{
							...(nameChanged && { name: newName }),
							...(phoneChanged &&
								{ phone: form.data.phoneNumber }),
						},
					);
				}
			});

			return message(form, { success: "Profile has been updated!" });
		} catch (err) {
			Sentry.captureMessage(
				`Error updating member profile: ${err}`,
				"error",
			);
			setMessage(form, { failure: "Failed to update profile" });
			return fail(500, {
				form,
			});
		}
	},
};
