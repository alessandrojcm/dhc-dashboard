import * as Sentry from "@sentry/sveltekit";
import { type Actions, error, type ServerLoadEvent } from "@sveltejs/kit";
import { fail, message, setMessage, superValidate } from "sveltekit-superforms";
import { valibot } from "sveltekit-superforms/adapters";
import signupSchema from "$lib/schemas/membersSignup";
import { invariant } from "$lib/server/invariant";
import { getRolesFromSession, SETTINGS_ROLES } from "$lib/server/roles";
import { supabaseServiceClient } from "$lib/server/supabaseServiceClient";
import type { SocialMediaConsent } from "$lib/types.ts";
import type { RequestEvent } from "../$types";
import type { PageServerLoad } from "./$types";
import {
	createMemberService,
	createProfileService,
} from "$lib/server/services/members";

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
	const { params, locals, platform } = event;
	const { session } = await locals.safeGetSession();

	if (!session || !platform?.env.HYPERDRIVE) {
		return error(401, "Unauthorized");
	}

	try {
		const canUpdate = await canUpdateSettings(event);
		const memberService = createMemberService(platform, session);

		// Get member data
		const memberProfile = await memberService.findById(params.memberId);

		if (
			!canUpdate &&
			(!memberProfile || params.memberId !== locals.session?.user.id)
		) {
			return error(404, "Member not found");
		}

		const email = await supabaseServiceClient.auth.admin
			.getUserById(params.memberId)
			.then((r) => r.data.user?.email ?? "");

		// Get member data with subscription info
		const memberData = await memberService.findByIdWithSubscription(
			params.memberId,
		);

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
					medicalConditions: memberProfile.medical_conditions ?? undefined,
					nextOfKin: memberProfile.next_of_kin_name ?? undefined,
					nextOfKinNumber: memberProfile.next_of_kin_phone ?? undefined,
					weapon: memberProfile.preferred_weapon ?? undefined,
					insuranceFormSubmitted:
						memberProfile.insurance_form_submitted ?? undefined,
					socialMediaConsent:
						(memberProfile.social_media_consent as SocialMediaConsent) ??
						undefined,
				},
				valibot(signupSchema),
				{ errors: false },
			),
			genders: locals.supabase
				.rpc("get_gender_options")
				.then((r) => r.data ?? []) as Promise<string[]>,
			weapons: locals.supabase
				.rpc("get_weapons_options")
				.then((r) => r.data ?? []) as Promise<string[]>,
			insuranceFormLink: supabaseServiceClient
				.from("settings")
				.select("value")
				.eq("key", "insurance_form_link")
				.limit(1)
				.single()
				.then((result) => result.data?.value),
			member: {
				id: params.memberId,
				customer_id: memberData?.customer_id,
				subscription_paused_until: memberData?.subscription_paused_until,
			},
			canUpdate,
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
			return fail(422, { form });
		}

		const { session } = await event.locals.safeGetSession();
		if (!session || !event.platform?.env.HYPERDRIVE) {
			return fail(401, { form, message: "Unauthorized" });
		}

		try {
			const profileService = createProfileService(event.platform, session);

			// Update profile with Stripe sync
			await profileService.updateProfile(event.params.memberId!, {
				firstName: form.data.firstName,
				lastName: form.data.lastName,
				phoneNumber: form.data.phoneNumber,
				dateOfBirth: form.data.dateOfBirth,
				pronouns: form.data.pronouns,
				gender: form.data.gender as any,
				medicalConditions: form.data.medicalConditions,
				nextOfKin: form.data.nextOfKin,
				nextOfKinNumber: form.data.nextOfKinNumber,
				preferredWeapon: form.data.weapon as any,
				insuranceFormSubmitted: form.data.insuranceFormSubmitted,
				socialMediaConsent: form.data.socialMediaConsent as any,
			});

			return message(form, { success: "Profile has been updated!" });
		} catch (err) {
			Sentry.captureMessage(`Error updating member profile: ${err}`, "error");
			setMessage(form, { failure: "Failed to update profile" });
			return fail(500, { form });
		}
	},
};
