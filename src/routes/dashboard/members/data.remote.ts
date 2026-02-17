import { command, form, getRequestEvent } from "$app/server";
import {
	InsuranceFormLinkSchema,
	createSettingsService,
} from "$lib/server/services/settings";
import { invariant } from "$lib/server/invariant";
import {
	getRolesFromSession,
	SETTINGS_ROLES,
	allowedToggleRoles,
} from "$lib/server/roles";
import {
	adminInviteRemoteSchema,
	bulkInviteRemoteSchema,
	bulkInviteSchema,
} from "$lib/schemas/adminInvite";
import * as v from "valibot";

/**
 * Validates a single invite entry (used for adding to the bulk list)
 * This doesn't submit to server - just validates the data
 */
export const validateSingleInvite = form(
	adminInviteRemoteSchema,
	async (data) => {
		// This form is used for validation only on the client side
		// Return the validated data
		return { invite: data };
	},
);

/**
 * Submits bulk invites to the edge function
 */
export const submitBulkInvites = command(
	bulkInviteRemoteSchema,
	async (data) => {
		const event = getRequestEvent();
		const { session } = await event.locals.safeGetSession();

		invariant(session === null, "Unauthorized");
		const roles = getRolesFromSession(session!);
		invariant(
			roles.intersection(allowedToggleRoles).size === 0,
			"Unauthorized",
			403,
		);

		// Transform string dates to Date objects for the full schema validation
		const transformedData = {
			invites: data.invites.map((invite) => ({
				...invite,
				dateOfBirth: new Date(invite.dateOfBirth),
			})),
		};

		// Validate with the full complex schema (includes cross-field validation and transformations)
		const validationResult = v.safeParse(bulkInviteSchema, transformedData);
		if (!validationResult.success) {
			const firstIssue = validationResult.issues[0];
			throw new Error(firstIssue?.message || "Invalid data format");
		}

		const { output: validatedData } = validationResult;

		if (validatedData.invites.length === 0) {
			throw new Error("No invites to send");
		}

		const supabase = event.locals.supabase;

		const response = await supabase.functions.invoke(
			"bulk_invite_with_subscription",
			{
				body: { invites: validatedData.invites },
				method: "POST",
			},
		);

		if (response.error) {
			throw new Error("Failed to process invitations. Please try again later.");
		}

		return {
			success:
				"Invitations are being processed in the background. You will be notified when completed.",
		};
	},
);

export const updateMemberSettings = form(
	InsuranceFormLinkSchema,
	async (data) => {
		const event = getRequestEvent();
		const { session } = await event.locals.safeGetSession();

		invariant(session === null, "Unauthorized");
		const roles = getRolesFromSession(session!);
		invariant(
			roles.intersection(SETTINGS_ROLES).size === 0,
			"Unauthorized",
			403,
		);

		const settingsService = createSettingsService(event.platform!, session!);
		await settingsService.updateInsuranceFormLink(data.insuranceFormLink);

		return { success: "Settings updated successfully" };
	},
);
