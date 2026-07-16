import { describe, expect, it, vi } from "vitest";
import { submitWorkshopAttendance } from "./workshop-attendance";

const { workshopsUpdateAttendance } = vi.hoisted(() => ({
	workshopsUpdateAttendance: vi.fn(),
}));

vi.mock("@dhc/api-client", async (importOriginal) => ({
	...(await importOriginal<typeof import("@dhc/api-client")>()),
	workshopsUpdateAttendance,
}));

describe("submitWorkshopAttendance", () => {
	it("sends the authenticated coordinator's atomic updates through the generated client", async () => {
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
			{
				access_token: "coordinator-token",
			} as never,
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
			auth: "coordinator-token",
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
