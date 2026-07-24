import { form, getRequestEvent } from "$app/server";
import { membersUpdate } from "@dhc/api-client";
import * as v from "valibot";
import formSchema, {
	memberProfileClientSchema,
} from "$lib/schemas/membersSignup";
import { invariant } from "$lib/server/invariant";
import { getRolesFromSession, MEMBERS_ADMIN_ROLES } from "$lib/server/roles";
import { apiClientOptions } from "$lib/server/api-client";
import { invalid } from "@sveltejs/kit";

/**
 * ALE-164: the self-vs-admin check no longer reads the Supabase `user.id` —
 * the Phoenix session projection carries the principal id directly as
 * `session.principal.id`. Self-access is granted when the requested
 * `memberId` matches the session principal.
 */
async function canUpdateSettings() {
	const event = getRequestEvent();
	const { session } = await event.locals.safeGetSession();
	invariant(session === null, "Unauthorized");
	const roles = getRolesFromSession(session!);
	if (roles.intersection(MEMBERS_ADMIN_ROLES).size > 0) {
		return true;
	}
	// Self-access: the requested member id matches the signed-in principal.
	return event.params.memberId === session!.principal.id;
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
		if (!session) {
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

		try {
			const response = await membersUpdate({
				...apiClientOptions(event.cookies),
				path: { memberId },
				body: {
					firstName: data.firstName,
					lastName: data.lastName,
					phoneNumber: data.phoneNumber,
					dateOfBirth: data.dateOfBirth,
					pronouns: data.pronouns,
					gender: data.gender,
					medicalConditions: data.medicalConditions,
					nextOfKinName: data.nextOfKin,
					nextOfKinPhone: data.nextOfKinNumber,
					preferredWeapon: data.weapon,
					insuranceFormSubmitted: data.insuranceFormSubmitted,
					socialMediaConsent: data.socialMediaConsent,
				},
			});
			if (response.error) {
				return {
					error: response.error.errors?.detail ?? "Failed to update profile",
				};
			}

			return { success: "Profile has been updated!" };
		} catch (e) {
			console.error(e);
			return { error: "Failed to update profile" };
		}
	},
);
