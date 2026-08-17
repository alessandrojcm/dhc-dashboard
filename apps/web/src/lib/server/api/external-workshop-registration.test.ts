import { beforeEach, describe, expect, it, vi } from "vitest";
import {
	completeExternalWorkshopRegistration,
	createExternalWorkshopCheckoutSession,
	getExternalWorkshopRegistrationGate,
	type ExternalWorkshopRegistrationClient,
} from "./external-workshop-registration";

const workshopsCompleteExternalRegistration =
	vi.fn<ExternalWorkshopRegistrationClient["completeRegistration"]>();
const workshopsCreateExternalCheckoutSession =
	vi.fn<ExternalWorkshopRegistrationClient["createCheckoutSession"]>();
const workshopsExternalRegistrationGate =
	vi.fn<ExternalWorkshopRegistrationClient["registrationGate"]>();

const client: ExternalWorkshopRegistrationClient = {
	completeRegistration: workshopsCompleteExternalRegistration,
	createCheckoutSession: workshopsCreateExternalCheckoutSession,
	registrationGate: workshopsExternalRegistrationGate,
};

describe("external Workshop registration API", () => {
	beforeEach(() => vi.clearAllMocks());

	it("returns an eligible registration gate through the generated client", async () => {
		workshopsExternalRegistrationGate.mockResolvedValue({
			data: {
				data: {
					canRegister: true,
					workshop: {
						id: "workshop-1",
						title: "Public Workshop",
						startDate: "2026-08-20T10:00:00Z",
						endDate: "2026-08-20T12:00:00Z",
						location: "Dublin",
						priceNonMember: 2500,
						maxCapacity: 20,
					},
				},
			},
		});

		const result = await getExternalWorkshopRegistrationGate(
			"workshop-1",
			client,
		);

		expect(workshopsExternalRegistrationGate).toHaveBeenCalledWith({
			baseUrl: "http://127.0.0.1:4000/api",
			path: { workshopId: "workshop-1" },
		});
		expect(result.canRegister).toBe(true);
	});

	it("preserves an ineligible gate reason", async () => {
		workshopsExternalRegistrationGate.mockResolvedValue({
			data: { data: { canRegister: false, reason: "FULL" } },
		});

		await expect(
			getExternalWorkshopRegistrationGate("workshop-1", client),
		).resolves.toEqual({ canRegister: false, reason: "FULL" });
	});

	it("completes a successful paid registration through the generated client", async () => {
		workshopsCompleteExternalRegistration.mockResolvedValue({
			data: {
				data: { registration: { id: "registration-1", status: "confirmed" } },
			},
		});

		await expect(
			completeExternalWorkshopRegistration("workshop-1", "cs_paid", client),
		).resolves.toEqual({ id: "registration-1", status: "confirmed" });
		expect(workshopsCompleteExternalRegistration).toHaveBeenCalledWith({
			baseUrl: "http://127.0.0.1:4000/api",
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
			completeExternalWorkshopRegistration("workshop-1", "cs_paid", client),
		).rejects.toMatchObject({ code: "WORKSHOP_FULL" });
	});

	it("surfaces payment-provider checkout failures", async () => {
		workshopsCreateExternalCheckoutSession.mockResolvedValue({
			error: { errors: { detail: "Payment provider request failed" } },
		});

		await expect(
			createExternalWorkshopCheckoutSession(
				"workshop-1",
				"7f8f909d-f2d8-4cc4-bcb4-2f31097f7903",
				"https://example.com/confirmation?session_id={CHECKOUT_SESSION_ID}",
				client,
			),
		).rejects.toMatchObject({ code: "PAYMENT_FAILED" });
	});
});
