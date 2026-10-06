import { form, getRequestEvent } from "$app/server";
import { membersUpdate, type MemberUpdateRequest } from "@dhc/api-client";
import memberProfileSchema from "#lib/schemas/memberProfile.js";
import { authorizationFor } from "#lib/server/authorization/index.js";
import { apiClientOptions } from "#lib/server/api-client.js";

/**
 * Member profile edit form. The schema's output is the Phoenix request body,
 * so the validated data is sent unchanged.
 */
export const updateProfile = form(memberProfileSchema, async (data) => {
	const event = getRequestEvent();
	const memberId = event.params.memberId;
	if (!memberId) throw new Error("Member ID is required");

	// GH-510: same contextual rule as the profile page load — the owner or
	// a member administrator may update; anyone else gets the decision's
	// status (401 anonymous, 404 concealed).
	const { session } = await event.locals.safeGetSession();
	authorizationFor(session).require("members.profile.update", {
		ownerPrincipalId: memberId,
	});

	try {
		const response = await membersUpdate({
			...apiClientOptions(event.cookies),
			path: { memberId },
			body: data satisfies MemberUpdateRequest,
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
});
