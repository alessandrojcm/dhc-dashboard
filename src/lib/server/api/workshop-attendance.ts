import {
	workshopsUpdateAttendance,
	type ApiErrorResponse,
} from "@dhc/api-client";
import { apiClientOptions } from "$lib/server/api-client";
import type { Session } from "@supabase/supabase-js";

export type WorkshopAttendanceUpdate = {
	registrationId: string;
	attendanceStatus: "attended" | "noShow" | "excused";
	notes?: string;
};

export async function submitWorkshopAttendance(
	session: Pick<Session, "access_token">,
	{
		workshopId,
		updates,
	}: { workshopId: string; updates: WorkshopAttendanceUpdate[] },
) {
	const response = await workshopsUpdateAttendance({
		...apiClientOptions(session),
		path: { workshopId },
		body: { updates },
	});

	if (response.error) {
		throw new Error(
			(response.error as ApiErrorResponse).errors?.detail ??
				"Failed to update workshop attendance. Please try again later.",
		);
	}

	return response.data.data.registrations;
}
