import { command, getRequestEvent } from "$app/server";
import { PUBLIC_SITE_URL } from "$env/static/public";
import * as v from "valibot";
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
		const { locals, platform } = getRequestEvent();
		const session = await authorize(locals, SETTINGS_ROLES);

		const service = createInvitationService(platform!, session);
		const siteUrl = PUBLIC_SITE_URL ?? "http://localhost:5173";
		const result = await service.resendInvitations(emails, siteUrl);

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
