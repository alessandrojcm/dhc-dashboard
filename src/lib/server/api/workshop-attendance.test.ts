import { describe, expect, it, vi } from "vitest";
import { submitWorkshopAttendance } from "./workshop-attendance";

const { workshopsUpdateAttendance } = vi.hoisted(() => ({
	workshopsUpdateAttendance: vi.fn(),
}));

vi.mock("@dhc/api-client", async (importOriginal) => ({
	...(await importOriginal<typeof import("@dhc/api-client")>()),
	workshopsUpdateAttendance,
}));

// ALE-164: the helper now takes a `Cookies` (SvelteKit request cookies) and
// forwards the `_dhc_session` cookie to Phoenix, instead of the prior Supabase
// `access_token`.
function fakeCookies(sessionCookie: string | undefined): {
	get: (name: string) => string | undefined;
} {
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
		);

		expect(workshopsUpdateAttendance).toHaveBeenCalledWith({
			baseUrl: "http://localhost:4000/api",
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
			},
		]);
	});
});
