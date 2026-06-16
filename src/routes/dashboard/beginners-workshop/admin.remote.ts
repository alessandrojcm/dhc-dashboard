import { command, getRequestEvent, query } from "$app/server";
import {
	invitationsResend,
	waitlistAnalytics,
	waitlistEntries,
} from "@dhc/api-client";
import * as v from "valibot";
import { apiClientOptions } from "$lib/server/api-client";
import { authorize } from "$lib/server/auth";
import { SETTINGS_ROLES, WAITLIST_ADMIN_ROLES } from "$lib/server/roles";
import { createInvitationService } from "$lib/server/services/invitations";

const waitlistEntrySortFields = [
	"current_position",
	"full_name",
	"status",
	"age",
	"initial_registration_date",
	"last_contacted",
	"last_status_change",
] as const;

const waitlistEntrySortMap = {
	current_position: "position",
	full_name: "fullName",
	status: "status",
	age: "age",
	initial_registration_date: "initialRegistrationDate",
	last_contacted: "lastContacted",
	last_status_change: "lastStatusChange",
} as const;

const waitlistEntryStatusValues = [
	"waiting",
	"invited",
	"paid",
	"deferred",
	"cancelled",
	"completed",
	"no_reply",
	"joined",
] as const;

const waitlistEntriesSchema = v.object({
	limit: v.optional(v.picklist([10, 25, 50, 100] as const), 10),
	cursor: v.optional(v.nullable(v.string())),
	q: v.optional(v.string()),
	status: v.optional(v.picklist(waitlistEntryStatusValues)),
	sort: v.optional(v.picklist(waitlistEntrySortFields), "current_position"),
	direction: v.optional(v.picklist(["asc", "desc"] as const), "asc"),
});

export const getWaitlistAnalytics = query(async () => {
	const { locals } = getRequestEvent();
	const session = await authorize(locals, WAITLIST_ADMIN_ROLES);

	const response = await waitlistAnalytics({
		...apiClientOptions(session),
	});

	if (response.error) {
		throw new Error(
			"Failed to load waitlist analytics. Please try again later.",
		);
	}

	return response.data.data;
});

export const getWaitlistEntries = query(
	waitlistEntriesSchema,
	async (params) => {
		const { locals } = getRequestEvent();
		const session = await authorize(locals, WAITLIST_ADMIN_ROLES);

		const response = await waitlistEntries({
			...apiClientOptions(session),
			query: {
				limit: params.limit,
				cursor: params.cursor ?? undefined,
				q: params.q || undefined,
				status: params.status,
				sort: waitlistEntrySortMap[params.sort],
				direction: params.direction,
			},
		});

		if (response.error) {
			throw new Error(
				"Failed to load waitlist entries. Please try again later.",
			);
		}

		return response.data.data;
	},
);

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
