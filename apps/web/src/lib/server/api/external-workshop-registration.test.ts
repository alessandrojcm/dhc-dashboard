import { beforeEach, describe, expect, it, vi } from "vitest";
import {
	completeExternalWorkshopRegistration,
	createExternalWorkshopCheckoutSession,
	getExternalWorkshopRegistrationGate,
} from "./external-workshop-registration";

const {
	workshopsCompleteExternalRegistration,
	workshopsCreateExternalCheckoutSession,
	workshopsExternalRegistrationGate,
} = vi.hoisted(() => ({
	workshopsCompleteExternalRegistration: vi.fn(),
	workshopsCreateExternalCheckoutSession: vi.fn(),
	workshopsExternalRegistrationGate: vi.fn(),
}));

vi.mock("@dhc/api-client", async (importOriginal) => ({
	...(await importOriginal<typeof import("@dhc/api-client")>()),
	workshopsCompleteExternalRegistration,
	workshopsCreateExternalCheckoutSession,
	workshopsExternalRegistrationGate,
}));

describe("external Workshop registration API", () => {
	beforeEach(() => vi.clearAllMocks());

	it("returns an eligible registration gate through the generated client", async () => {
		workshopsExternalRegistrationGate.mockResolvedValue({
			data: {
				data: {
					canRegister: true,
					workshop: { id: "workshop-1", title: "Public Workshop" },
				},
			},
		});

		const result = await getExternalWorkshopRegistrationGate("workshop-1");

		expect(workshopsExternalRegistrationGate).toHaveBeenCalledWith({
			baseUrl: "http://localhost:4000/api",
			path: { workshopId: "workshop-1" },
		});
		expect(result.canRegister).toBe(true);
	});

	it("preserves an ineligible gate reason", async () => {
		workshopsExternalRegistrationGate.mockResolvedValue({
			data: { data: { canRegister: false, reason: "FULL" } },
		});

		await expect(
			getExternalWorkshopRegistrationGate("workshop-1"),
		).resolves.toEqual({ canRegister: false, reason: "FULL" });
	});

	it("completes a successful paid registration through the generated client", async () => {
		workshopsCompleteExternalRegistration.mockResolvedValue({
			data: {
				data: { registration: { id: "registration-1", status: "confirmed" } },
			},
		});

		await expect(
			completeExternalWorkshopRegistration("workshop-1", "cs_paid"),
		).resolves.toEqual({ id: "registration-1", status: "confirmed" });
		expect(workshopsCompleteExternalRegistration).toHaveBeenCalledWith({
			baseUrl: "http://localhost:4000/api",
			path: { workshopId: "workshop-1" },
			body: { checkoutSessionId: "cs_paid" },
		});
	});

	it("surfaces a capacity race after paid checkout", async () => {
		workshopsCompleteExternalRegistration.mockResolvedValue({
			error: {
				errors: {
					detail: "Workshop is full; your payment has been refunded",
				},
			},
		});

		await expect(
			completeExternalWorkshopRegistration("workshop-1", "cs_paid"),
		).rejects.toMatchObject({ code: "WORKSHOP_FULL" });
	});

	it("surfaces payment-provider checkout failures", async () => {
		workshopsCreateExternalCheckoutSession.mockResolvedValue({
			error: { errors: { detail: "Payment provider request failed" } },
		});

		await expect(
			createExternalWorkshopCheckoutSession(
				"workshop-1",
				"https://example.com/confirmation?session_id={CHECKOUT_SESSION_ID}",
			),
		).rejects.toMatchObject({ code: "PAYMENT_FAILED" });
	});
});
