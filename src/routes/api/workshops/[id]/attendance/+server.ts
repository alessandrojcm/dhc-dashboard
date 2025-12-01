import * as Sentry from '@sentry/sveltekit';
import type { RequestHandler } from '@sveltejs/kit';
import { json } from '@sveltejs/kit';
import { safeParse } from 'valibot';
import { UpdateAttendanceSchema } from '$lib/schemas/attendance';
import { createAttendanceService } from '$lib/server/services/workshops';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';

export const GET: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const attendanceService = createAttendanceService(platform!, session);
		const attendance = await attendanceService.getWorkshopAttendance(params.id!);

		return json({ success: true, attendance });
	} catch (error) {
		Sentry.captureException(error);
		return json({ success: false, error: (error as Error).message }, { status: 500 });
	}
};

export const PUT: RequestHandler = async ({ request, locals, params, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const body = await request.json();
		const result = safeParse(UpdateAttendanceSchema, body);

		if (!result.success) {
			return json(
				{ success: false, error: 'Invalid data', issues: result.issues },
				{ status: 400 }
			);
		}

		const attendanceService = createAttendanceService(platform!, session);
		const updatedRegistrations = await attendanceService.updateAttendance(
			params.id!,
			result.output.attendance_updates
		);

		return json({ success: true, registrations: updatedRegistrations });
	} catch (error) {
		Sentry.captureException(error);
		return json({ success: false, error: (error as Error).message }, { status: 500 });
	}
};
