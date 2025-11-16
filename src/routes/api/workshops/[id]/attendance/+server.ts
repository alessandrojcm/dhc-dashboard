import * as Sentry from "@sentry/sveltekit";
import type { RequestHandler } from "@sveltejs/kit";
import { json } from "@sveltejs/kit";
import { safeParse } from "valibot";
import { UpdateAttendanceSchema } from "$lib/schemas/attendance";
import {
	getWorkshopAttendance,
	updateAttendance,
} from "$lib/server/attendance";
import { authorize } from "$lib/server/auth";
import { WORKSHOP_ROLES } from "$lib/server/roles";

export const GET: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const attendance = await getWorkshopAttendance(
			params.id!,
			session,
			platform!,
		);

		return json({ success: true, attendance });
	} catch (error) {
		Sentry.captureException(error);
		return json(
			{ success: false, error: (error as Error).message },
			{ status: 500 },
		);
	}
};

export const PUT: RequestHandler = async ({
	request,
	locals,
	params,
	platform,
}) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const body = await request.json();
		const result = safeParse(UpdateAttendanceSchema, body);

		if (!result.success) {
			return json(
				{ success: false, error: "Invalid data", issues: result.issues },
				{ status: 400 },
			);
		}

		const updatedRegistrations = await updateAttendance(
			params.id!,
			result.output.attendance_updates,
			session,
			platform!,
		);

		return json({ success: true, registrations: updatedRegistrations });
	} catch (error) {
		Sentry.captureException(error);
		return json(
			{ success: false, error: (error as Error).message },
			{ status: 500 },
		);
	}
};
