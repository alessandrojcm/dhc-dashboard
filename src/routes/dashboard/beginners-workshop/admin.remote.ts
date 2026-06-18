import { command, getRequestEvent } from "$app/server";
import { invitationsResend } from "@dhc/api-client";
import * as v from "valibot";
import { apiClientOptions } from "$lib/server/api-client";
import { authorize } from "$lib/server/auth";
import { SETTINGS_ROLES } from "$lib/server/roles";
import { createInvitationService } from "$lib/server/services/invitations";

export const resendInvitations = command(
	v.object({
		emails: v.pipe(
			v.array(v.pipe(v.string(), v.email())),
			v.minLength(1, "At least one email is required"),
		),
	}),
	async ({ emails }) => {
		const { locals } = getRequestEvent();
		const session = await authorize(locals, SETTINGS_ROLES);

		const response = await invitationsResend({
			...apiClientOptions(session),
			body: { emails },
		});

		if (response.error) {
			throw new Error("Failed to resend invitations. Please try again later.");
		}

		const result = response.data.data ?? {
			succeeded: 0,
			failed: emails.length,
		};

		return { success: true as const, ...result };
	},
);

export const deleteInvitations = command(
	v.pipe(
		v.array(v.pipe(v.string(), v.uuid())),
		v.minLength(1, "At least one invitation ID is required"),
	),
	async (invitationIds) => {
		const { locals, platform } = getRequestEvent();
		const session = await authorize(locals, SETTINGS_ROLES);

		const service = createInvitationService(platform!, session);
		await service.bulkDelete(invitationIds);

		return { success: true as const };
	},
);
