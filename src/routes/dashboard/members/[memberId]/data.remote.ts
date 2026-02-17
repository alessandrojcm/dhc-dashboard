import { form, getRequestEvent } from "$app/server";
import * as v from "valibot";
import formSchema, {
	memberProfileClientSchema,
} from "$lib/schemas/membersSignup";
import { invariant } from "$lib/server/invariant";
import { getRolesFromSession, SETTINGS_ROLES } from "$lib/server/roles";
import { createProfileService } from "$lib/server/services/members";
import { invalid } from "@sveltejs/kit";

async function canUpdateSettings() {
	const event = getRequestEvent();
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

export const updateProfile = form(
	memberProfileClientSchema,
	async (data, issue) => {
		const event = getRequestEvent();
		const memberId = event.params.memberId!;

		const canUpdate = await canUpdateSettings();
		if (!canUpdate) {
			throw new Error("Unauthorized");
		}

		const { session } = await event.locals.safeGetSession();
		if (!session || !event.platform?.env.HYPERDRIVE) {
			throw new Error("Unauthorized");
		}

		// Transform client data (string dateOfBirth) to server types (Date) for complex schema validation
		const transformedData = {
			...data,
			dateOfBirth: new Date(data.dateOfBirth),
		};

		// Validate with the full complex schema (includes cross-field validation and transformations)
		const result = v.safeParse(formSchema, transformedData);

		if (!result.success) {
			// Map Valibot validation errors to form field issues
			for (const validationIssue of result.issues) {
				const fieldPath =
					validationIssue.path?.map((p) => p.key).join(".") || "";
				if (fieldPath) {
					// Create field-specific issue using dynamic property access
					// eslint-disable-next-line @typescript-eslint/no-explicit-any
					const issueProxy = issue as any;
					if (typeof issueProxy[fieldPath] === "function") {
						invalid(issueProxy[fieldPath](validationIssue.message));
					}
				} else {
					// Form-level error
					invalid(validationIssue.message);
				}
			}
			return;
		}

		const profileService = createProfileService(event.platform, session);

		// Convert dateOfBirth string to Date (required field)
		const dateOfBirth = new Date(data.dateOfBirth);

		try {
			await profileService.updateProfile(memberId, {
				firstName: data.firstName,
				lastName: data.lastName,
				phoneNumber: data.phoneNumber,
				dateOfBirth,
				pronouns: data.pronouns,
				gender: data.gender as
					| "male"
					| "female"
					| "non_binary"
					| "prefer_not_to_say"
					| "other"
					| undefined,
				medicalConditions: data.medicalConditions,
				nextOfKin: data.nextOfKin,
				nextOfKinNumber: data.nextOfKinNumber,
				preferredWeapon: data.weapon,
				insuranceFormSubmitted: data.insuranceFormSubmitted,
				socialMediaConsent: data.socialMediaConsent as
					| "yes"
					| "no"
					| "ask_me"
					| undefined,
			});

			return { success: "Profile has been updated!" };
		} catch (e) {
			console.error(e);
			return { error: "Failed to update profile" };
		}
	},
);
