import { describe, expect, it, vi } from "vitest";
import {
	submitWorkshopAttendance,
	type WorkshopAttendanceClient,
} from "./workshop-attendance";

const workshopsUpdateAttendance =
	vi.fn<WorkshopAttendanceClient["updateAttendance"]>();
const client: WorkshopAttendanceClient = {
	updateAttendance: workshopsUpdateAttendance,
};

// ALE-164: the helper now takes a `Cookies` (SvelteKit request cookies) and
// forwards the `_dhc_session` cookie to Phoenix, instead of the prior Supabase
// `access_token`.
function fakeCookies(sessionCookie: string | undefined) {
	return {
		get: (name: string) =>
			name === "_dhc_session" ? sessionCookie : undefined,
	};
}

describe("submitWorkshopAttendance", () => {
	it("sends the authenticated coordinator's atomic updates through the generated client with the session cookie", async () => {
		workshopsUpdateAttendance.mockResolvedValue({
			data: {
				data: {
					registrations: [
						{
							id: "22222222-2222-2222-2222-222222222222",
							attendanceStatus: "attended",
							attendanceMarkedAt: "2026-08-16T10:00:00Z",
							attendanceMarkedBy: "coordinator-1",
							attendanceNotes: "Present",
						},
					],
				},
			},
		});

		const result = await submitWorkshopAttendance(
			fakeCookies("signed-session-cookie"),
			{
				workshopId: "11111111-1111-1111-1111-111111111111",
				updates: [
					{
						registrationId: "22222222-2222-2222-2222-222222222222",
						attendanceStatus: "attended",
						notes: "Present",
					},
				],
			},
			client,
		);

		expect(workshopsUpdateAttendance).toHaveBeenCalledWith({
			baseUrl: "http://127.0.0.1:4000/api",
			credentials: "include",
			headers: { cookie: "_dhc_session=signed-session-cookie" },
			path: { workshopId: "11111111-1111-1111-1111-111111111111" },
			body: {
				updates: [
					{
						registrationId: "22222222-2222-2222-2222-222222222222",
						attendanceStatus: "attended",
						notes: "Present",
					},
				],
			},
		});
		expect(result).toEqual([
			{
				id: "22222222-2222-2222-2222-222222222222",
				attendanceStatus: "attended",
				attendanceMarkedAt: "2026-08-16T10:00:00Z",
				attendanceMarkedBy: "coordinator-1",
				attendanceNotes: "Present",
			},
		]);
	});
});
