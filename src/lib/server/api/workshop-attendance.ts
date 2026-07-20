import {
	workshopsUpdateAttendance,
	type ApiErrorResponse,
} from "@dhc/api-client";
import { apiClientOptions, type Cookies } from "$lib/server/api-client";

export type WorkshopAttendanceUpdate = {
	registrationId: string;
	attendanceStatus: "attended" | "noShow" | "excused";
	notes?: string;
};

/**
 * ALE-164: takes a `Cookies` (SvelteKit request cookies) and forwards the
 * `_dhc_session` cookie to Phoenix, instead of the prior Supabase
 * `access_token`.
 */
export async function submitWorkshopAttendance(
	cookies: Cookies,
	{
		workshopId,
		updates,
	}: { workshopId: string; updates: WorkshopAttendanceUpdate[] },
) {
	const response = await workshopsUpdateAttendance({
		...apiClientOptions(cookies),
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
