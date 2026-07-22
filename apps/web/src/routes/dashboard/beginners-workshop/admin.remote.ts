import { command, getRequestEvent } from "$app/server";
import { invitationsDelete, invitationsResend } from "@dhc/api-client";
import * as v from "valibot";
import { apiClientOptions } from "$lib/server/api-client";
import { authorize } from "$lib/server/auth";
import { SETTINGS_ROLES } from "$lib/server/roles";

export const resendInvitations = command(
	v.object({
		emails: v.pipe(
			v.array(v.pipe(v.string(), v.email())),
			v.minLength(1, "At least one email is required"),
		),
	}),
	async ({ emails }) => {
		const event = getRequestEvent();
		await authorize(event.locals, SETTINGS_ROLES);

		const response = await invitationsResend({
			...apiClientOptions(event.cookies),
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
		const event = getRequestEvent();
		await authorize(event.locals, SETTINGS_ROLES);

		const response = await invitationsDelete({
			...apiClientOptions(event.cookies),
			body: { invitationIds },
		});

		if (response.error) {
			throw new Error("Failed to delete invitations. Please try again later.");
		}

		return { success: true as const };
	},
);
