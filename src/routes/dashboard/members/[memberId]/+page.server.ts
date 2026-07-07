import { membersInsuranceForm, membersShow, optionsIndex } from "@dhc/api-client";
import * as Sentry from "@sentry/sveltekit";
import { error, type ServerLoadEvent } from "@sveltejs/kit";
import { apiBaseUrl, apiClientOptions } from "$lib/server/api-client";
import { invariant } from "$lib/server/invariant";
import { getRolesFromSession, MEMBERS_ADMIN_ROLES } from "$lib/server/roles";
import type { SocialMediaConsent } from "$lib/types.ts";
import type { RequestEvent } from "../$types";
import type { PageServerLoad } from "./$types";

async function canUpdateSettings(event: RequestEvent | ServerLoadEvent) {
	const { session } = await event.locals.safeGetSession();
	invariant(session === null, "Unauthorized");
	const roles = getRolesFromSession(session!);
	if (roles.intersection(MEMBERS_ADMIN_ROLES).size > 0) {
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
	const { session } = await locals.safeGetSession();

	if (!session) {
		return error(401, "Unauthorized");
	}

	try {
		const canUpdate = await canUpdateSettings(event);
		const apiOptions = apiClientOptions(session);
		const memberResponse = await membersShow({
			...apiOptions,
			path: { memberId: params.memberId },
			throwOnError: true,
		});
		const memberProfile = memberResponse.data.data;

		if (
			!canUpdate &&
			(!memberProfile || params.memberId !== locals.session?.user.id)
		) {
			return error(404, "Member not found");
		}

		const options = optionsIndex({ baseUrl: apiBaseUrl() }).then(
			(response) => response.data?.data ?? { genders: [], weapons: [] },
		);
		const preferredWeapon = (memberProfile.preferredWeapon ?? []).filter(
			(weapon): weapon is string => typeof weapon === "string",
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
				socialMediaConsent: memberProfile.socialMediaConsent as
					| SocialMediaConsent
					| undefined,
			},
			genders: options.then((data) => data.genders),
			weapons: options.then((data) => data.weapons),
			insuranceFormLink: membersInsuranceForm({
				...apiOptions,
			})
				.then((response) => response.data?.data.link ?? null)
				.catch(() => null),
			member: {
				id: params.memberId,
				subscription_paused_until: memberProfile.subscriptionPausedUntil,
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
