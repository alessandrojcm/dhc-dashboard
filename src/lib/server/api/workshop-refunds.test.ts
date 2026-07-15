import { describe, expect, it, vi } from "vitest";
import { listWorkshopRefunds, submitWorkshopRefund } from "./workshop-refunds";

const { workshopsRefundRegistration, workshopsRefunds } = vi.hoisted(() => ({
	workshopsRefundRegistration: vi.fn(),
	workshopsRefunds: vi.fn(),
}));

vi.mock("@dhc/api-client", async (importOriginal) => ({
	...(await importOriginal<typeof import("@dhc/api-client")>()),
	workshopsRefundRegistration,
	workshopsRefunds,
}));

describe("Workshop refund API", () => {
	it("lists coordinator-visible refunds through the generated client", async () => {
		workshopsRefunds.mockResolvedValue({
			data: { data: { refunds: [{ id: "refund-1", status: "processing" }] } },
		});

		const result = await listWorkshopRefunds(
			{ access_token: "coordinator-token" } as never,
			"workshop-1",
		);

		expect(workshopsRefunds).toHaveBeenCalledWith({
			baseUrl: "http://localhost:4000/api",
			auth: "coordinator-token",
			path: { workshopId: "workshop-1" },
		});
		expect(result).toEqual([{ id: "refund-1", status: "processing" }]);
	});

	it("submits an explicit refund through the generated client", async () => {
		workshopsRefundRegistration.mockResolvedValue({
			data: { data: { refund: { id: "refund-1", status: "processing" } } },
		});

		const result = await submitWorkshopRefund(
			{ access_token: "coordinator-token" } as never,
			{
				workshopId: "workshop-1",
				registrationId: "registration-1",
				reason: "Requested by attendee",
			},
		);

		expect(workshopsRefundRegistration).toHaveBeenCalledWith({
			baseUrl: "http://localhost:4000/api",
			auth: "coordinator-token",
			path: {
				workshopId: "workshop-1",
				registrationId: "registration-1",
			},
			body: { reason: "Requested by attendee" },
		});
		expect(result).toEqual({ id: "refund-1", status: "processing" });
	});
});
