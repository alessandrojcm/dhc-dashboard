import {
	workshopsUpdateAttendance,
	type WorkshopAttendanceUpdateResponse,
} from "@dhc/api-client";
import { apiClientOptions, type Cookies } from "$lib/server/api-client";
import { apiErrorMessage } from "$lib/server/api-error";

export interface WorkshopAttendanceClient {
	updateAttendance(options: {
		baseUrl: string;
		credentials: "include";
		headers: Record<string, string>;
		path: { workshopId: string };
		body: { updates: WorkshopAttendanceUpdate[] };
	}): Promise<{
		data?: { data: WorkshopAttendanceUpdateResponse["data"] };
		error?: unknown;
	}>;
}

const defaultClient: WorkshopAttendanceClient = {
	updateAttendance: async (options) => workshopsUpdateAttendance(options),
};

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
	client: WorkshopAttendanceClient = defaultClient,
) {
	const response = await client.updateAttendance({
		...apiClientOptions(cookies),
		path: { workshopId },
		body: { updates },
	});

	if (response.error || !response.data) {
		throw new Error(
			apiErrorMessage(
				response.error,
				"Failed to update workshop attendance. Please try again later.",
			),
		);
	}

	return response.data.data.registrations;
}
