import { command, form, getRequestEvent } from "$app/server";
import {
	invitationsCreate,
	settingsUpdate,
	type InvitationCreateRequest,
} from "@dhc/api-client";
import { apiClientOptions } from "#lib/server/api-client.js";
import { InsuranceFormLinkSchema } from "#lib/schemas/settings.js";
import { authorizationFor } from "#lib/server/authorization/index.js";
import { bulkInviteSchema } from "#lib/schemas/adminInvite.js";

/**
 * Submits bulk invites to the API. The schema output is the
 * `invitationsCreate` body, so it is sent unchanged.
 */
export const submitBulkInvites = command(bulkInviteSchema, async (data) => {
	const event = getRequestEvent();
	const { session } = await event.locals.safeGetSession();
	authorizationFor(session).require("members.invite");

	const response = await invitationsCreate({
		...apiClientOptions(event.cookies),
		body: data satisfies InvitationCreateRequest,
	});

	if (response.error) {
		throw new Error("Failed to process invitations. Please try again later.");
	}

	return {
		success:
			"Invitations are being processed in the background. You will be notified when completed.",
	};
});

export const updateMemberSettings = form(
	InsuranceFormLinkSchema,
	async (data) => {
		const event = getRequestEvent();
		const { session } = await event.locals.safeGetSession();
		authorizationFor(session).require("members.settings.edit");

		const response = await settingsUpdate({
			...apiClientOptions(event.cookies),
			path: { key: "hema_insurance_form_link" },
			body: { value: data.insuranceFormLink },
		});

		if (response.error) {
			throw new Error(
				response.error.errors?.detail ??
					"Failed to update settings. Please try again later.",
			);
		}

		return { success: "Settings updated successfully" };
	},
);
