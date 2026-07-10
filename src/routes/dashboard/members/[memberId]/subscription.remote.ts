import { command, getRequestEvent } from "$app/server";
import { error } from "@sveltejs/kit";
import dayjs from "dayjs";
import * as v from "valibot";
import { authorize } from "$lib/server/auth";
import { SETTINGS_ROLES } from "$lib/server/roles";
import { apiBaseUrl, apiClientOptions } from "$lib/server/api-client";
import { membershipPause, membershipResume } from "@dhc/api-client";

export const pauseSubscription = command(
	v.object({
		memberId: v.pipe(v.string(), v.uuid()),
		pauseUntil: v.pipe(
			v.string(),
			v.transform((str) => new Date(str)),
			v.check((date) => {
				const pauseDate = dayjs(date);
				const now = dayjs();
				const minDate = now.add(1, "day");
				const maxDate = now.add(6, "months");
				return pauseDate.isAfter(minDate) && pauseDate.isBefore(maxDate);
			}, "Pause date must be between 1 day and 6 months from now"),
		),
	}),
	async ({ memberId, pauseUntil }) => {
		const { locals } = getRequestEvent();
		const { session } = await locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		if (session.user.id !== memberId) {
			await authorize(locals, SETTINGS_ROLES);
		}

		const response = await membershipPause({
			...apiClientOptions(session),
			path: { memberId },
			body: { pauseUntil: pauseUntil.toISOString() },
			throwOnError: false,
		});

		if (response.error) {
			error(response.response?.status ?? 500, "Failed to pause membership");
		}

		return { success: true as const, member: response.data!.data };
	},
);

export const resumeSubscription = command(
	v.pipe(v.string(), v.uuid()),
	async (memberId) => {
		const { locals } = getRequestEvent();
		const { session } = await locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		if (session.user.id !== memberId) {
			await authorize(locals, SETTINGS_ROLES);
		}

		const response = await membershipResume({
			...apiClientOptions(session),
			path: { memberId },
			throwOnError: false,
		});

		if (response.error) {
			error(response.response?.status ?? 500, "Failed to resume membership");
		}

		return { success: true as const, member: response.data!.data };
	},
);