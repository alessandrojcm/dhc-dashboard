import { command, getRequestEvent } from "$app/server";
import { error } from "@sveltejs/kit";
import dayjs from "dayjs";
import * as v from "valibot";
import { authorize } from "$lib/server/auth";
import { SETTINGS_ROLES } from "$lib/server/roles";
import { createSubscriptionService } from "$lib/server/services/members";

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
		const { locals, platform } = getRequestEvent();
		const { session } = await locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		if (session.user.id !== memberId) {
			await authorize(locals, SETTINGS_ROLES);
		}

		const service = createSubscriptionService(platform!, session);
		const subscription = await service.pause(memberId, pauseUntil);

		return { success: true as const, subscription };
	},
);

export const resumeSubscription = command(
	v.pipe(v.string(), v.uuid()),
	async (memberId) => {
		const { locals, platform } = getRequestEvent();
		const { session } = await locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		if (session.user.id !== memberId) {
			await authorize(locals, SETTINGS_ROLES);
		}

		const service = createSubscriptionService(platform!, session);
		const subscription = await service.resume(memberId);

		return { success: true as const, subscription };
	},
);
