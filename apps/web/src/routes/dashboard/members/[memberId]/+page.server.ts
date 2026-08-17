import { membersOptions, membersShow } from "@dhc/api-client";
import * as Sentry from "@sentry/sveltekit";
import { error, type ServerLoadEvent } from "@sveltejs/kit";
import { apiClientOptions } from "$lib/server/api-client";
import { getRolesFromSession, MEMBERS_ADMIN_ROLES } from "$lib/server/roles";
import { SocialMediaConsent as SocialMediaConsentValues } from "$lib/types";
import type { PageServerLoad } from "./$types";
import * as v from "valibot";

/**
 * ALE-164: the self-vs-admin check no longer reads the Supabase `user.id` —
 * the Phoenix session projection carries the principal id directly as
 * `session.principal.id`. Self-access is granted when the requested
 * `memberId` matches the session principal.
 */
async function canUpdateSettings(event: ServerLoadEvent): Promise<boolean> {
	const { session } = await event.locals.safeGetSession();
	if (!session) error(401, "Unauthorized");
	const roles = getRolesFromSession(session);
	if (roles.intersection(MEMBERS_ADMIN_ROLES).size > 0) {
		return true;
	}
	// Self-access: the requested member id matches the signed-in principal.
	return event.params.memberId === session.principal.id;
}

export const load: PageServerLoad = async (event) => {
	const { params, locals, cookies } = event;
	const { session } = await locals.safeGetSession();

	if (!session) {
		return error(401, "Unauthorized");
	}

	try {
		const canUpdate = await canUpdateSettings(event);
		const apiOptions = apiClientOptions(cookies);
		const [memberResponse, optionsResponse] = await Promise.all([
			membersShow({
				...apiOptions,
				path: { memberId: params.memberId },
				throwOnError: true,
			}),
			membersOptions({ ...apiOptions, throwOnError: true }),
		]);
		const memberProfile = memberResponse.data.data;
		const options = optionsResponse.data.data;

		// Self-access fallback: a non-admin may view only their own profile.
		// ALE-164: `session.principal.id` replaces the Supabase `user.id`.
		if (!canUpdate && params.memberId !== session.principal.id) {
			return error(404, "Member not found");
		}

		const preferredWeaponResult = v.safeParse(
			v.array(v.string()),
			memberProfile.preferredWeapon ?? [],
		);
		const preferredWeapon = preferredWeaponResult.success
			? preferredWeaponResult.output
			: [];
		const socialMediaConsentResult = v.safeParse(
			v.enum(SocialMediaConsentValues),
			memberProfile.socialMediaConsent,
		);

		return {
			profileData: {
				firstName: memberProfile.firstName ?? "",
				lastName: memberProfile.lastName ?? "",
				email: memberProfile.email ?? "",
				phoneNumber: memberProfile.phoneNumber ?? "",
				dateOfBirth: memberProfile.dateOfBirth ?? "",
				pronouns: memberProfile.pronouns ?? "",
				gender: memberProfile.gender ?? "",
				medicalConditions: memberProfile.medicalConditions ?? "",
				nextOfKin: memberProfile.nextOfKinName ?? "",
				nextOfKinNumber: memberProfile.nextOfKinPhone ?? "",
				weapon: preferredWeapon,
				insuranceFormSubmitted: memberProfile.insuranceFormSubmitted ?? false,
				socialMediaConsent: socialMediaConsentResult.success
					? socialMediaConsentResult.output
					: undefined,
			},
			genders: options.genders,
			weapons: options.weapons,
			member: {
				id: params.memberId,
				subscription_paused_until: memberProfile.subscriptionPausedUntil,
				discordIdentity: memberProfile.discordIdentity,
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
