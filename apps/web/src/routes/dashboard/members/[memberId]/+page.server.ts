import { membersOptions, membersShow } from "@dhc/api-client";
import * as Sentry from "@sentry/sveltekit";
import { error } from "@sveltejs/kit";
import { apiClientOptions } from "$lib/server/api-client";
import { authorizationFor } from "$lib/server/authorization";
import { SocialMediaConsent as SocialMediaConsentValues } from "$lib/types";
import type { PageServerLoad } from "./$types";
import * as v from "valibot";

export const load: PageServerLoad = async (event) => {
	const { params, locals, cookies, depends } = event;
	const { session } = await locals.safeGetSession();
	const access = authorizationFor(session);
	// GH-510: contextual "self or member administrator" rule. Ownership is an
	// explicit input (the requested member id); a non-owner without the
	// capability receives a concealed 404, an anonymous request a 401.
	const member = { ownerPrincipalId: params.memberId };
	access.require("members.profile.read", member);
	depends(`member:detail:${params.memberId}`);

	try {
		const canUpdate = access.can("members.profile.update", member);
		// ALE-252: reactivation mints new charges, so gate the UI on the same
		// four billing-authority roles the `:membership_minting_api` pipeline
		// enforces server-side (403 for everyone else, incl. self-service).
		const canReactivate = access.can("membership.reactivate");
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
				membership_status: memberProfile.membershipStatus,
				discordIdentity: memberProfile.discordIdentity,
			},
			canUpdate,
			canReactivate,
		};
	} catch (e) {
		Sentry.captureMessage(`Error loading member data: ${e}`, "error");
		error(404, {
			message: "Member not found",
		});
	}
};
