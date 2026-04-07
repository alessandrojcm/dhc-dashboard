import type { Stripe } from "stripe";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
	createMockLogger,
	createMockSession,
} from "$lib/server/services/shared/test-utils";
import { RegistrationService } from "./registration.service";

const executeWithRLSMock = vi.fn();

vi.mock("../shared", async () => {
	const actual = await vi.importActual<typeof import("../shared")>("../shared");

	return {
		...actual,
		executeWithRLS: (...args: unknown[]) => executeWithRLSMock(...args),
	};
});

function createStripeMock(): Stripe {
	return {
		checkout: {
			sessions: {
				create: vi.fn(),
				retrieve: vi.fn(),
			},
		},
	} as unknown as Stripe;
}

describe("RegistrationService - external checkout flow", () => {
	beforeEach(() => {
		executeWithRLSMock.mockReset();
	});

	it("creates an external checkout session with server-derived amount", async () => {
		const stripe = createStripeMock();
		(stripe.checkout.sessions.create as any).mockResolvedValue({
			id: "cs_test_123",
			url: null,
			client_secret: "cs_test_123_secret_abc",
		});

		const service = new RegistrationService(
			{} as never,
			createMockSession(),
			{ kind: "system" },
			stripe,
			createMockLogger(),
		);

		executeWithRLSMock.mockImplementation(async (_db, _claims, callback) =>
			callback({}),
		);

		vi.spyOn(
			service as any,
			"validateWorkshopForExternalRegistration",
		).mockResolvedValue({
			id: "workshop-1",
			title: "Public Intro Workshop",
			max_capacity: 20,
			price_non_member: 3500,
		});
		vi.spyOn(service as any, "checkWorkshopCapacity").mockResolvedValue(true);

		const result = await service.createExternalCheckoutSession({
			workshopId: "workshop-1",
			returnUrl:
				"https://example.com/workshops/workshop-1/confirmation?session_id={CHECKOUT_SESSION_ID}",
		});

		expect(result).toEqual({
			checkoutSessionId: "cs_test_123",
			checkoutClientSecret: "cs_test_123_secret_abc",
			checkoutUrl: null,
		});

		expect(stripe.checkout.sessions.create).toHaveBeenCalledWith(
			expect.objectContaining({
				mode: "payment",
				ui_mode: "embedded",
				return_url:
					"https://example.com/workshops/workshop-1/confirmation?session_id={CHECKOUT_SESSION_ID}",
				name_collection: {
					individual: {
						enabled: true,
						optional: false,
					},
				},
				line_items: [
					expect.objectContaining({
						price_data: expect.objectContaining({
							unit_amount: 3500,
							currency: "eur",
						}),
					}),
				],
				metadata: expect.objectContaining({
					type: "workshop_registration",
					actor_type: "external",
					workshop_id: "workshop-1",
				}),
			}),
		);
	});

	it("rejects checkout session creation when workshop is full", async () => {
		const stripe = createStripeMock();
		const service = new RegistrationService(
			{} as never,
			createMockSession(),
			{ kind: "system" },
			stripe,
			createMockLogger(),
		);

		executeWithRLSMock.mockImplementation(async (_db, _claims, callback) =>
			callback({}),
		);

		vi.spyOn(
			service as any,
			"validateWorkshopForExternalRegistration",
		).mockResolvedValue({
			id: "workshop-1",
			title: "Public Intro Workshop",
			max_capacity: 2,
			price_non_member: 3500,
		});
		vi.spyOn(service as any, "checkWorkshopCapacity").mockResolvedValue(false);

		await expect(
			service.createExternalCheckoutSession({
				workshopId: "workshop-1",
				returnUrl:
					"https://example.com/workshops/workshop-1/confirmation?session_id={CHECKOUT_SESSION_ID}",
			}),
		).rejects.toMatchObject({
			name: "ExternalRegistrationError",
			code: "WORKSHOP_FULL",
		});
	});

	it("rejects completion when checkout metadata does not match workshop", async () => {
		const stripe = createStripeMock();
		(stripe.checkout.sessions.retrieve as any).mockResolvedValue({
			id: "cs_test_123",
			status: "complete",
			payment_status: "paid",
			metadata: {
				type: "workshop_registration",
				actor_type: "external",
				workshop_id: "different-workshop",
			},
			customer_details: {
				email: "test@example.com",
				name: "Jane Doe",
				phone: null,
			},
			amount_total: 3500,
			currency: "eur",
		});

		const service = new RegistrationService(
			{} as never,
			createMockSession(),
			{ kind: "system" },
			stripe,
			createMockLogger(),
		);

		await expect(
			service.completeExternalRegistrationFromCheckoutSession({
				workshopId: "workshop-1",
				checkoutSessionId: "cs_test_123",
			}),
		).rejects.toMatchObject({
			name: "ExternalRegistrationError",
			code: "PAYMENT_METADATA_MISMATCH",
		});
	});

	it("returns existing registration for idempotent checkout session completion", async () => {
		const stripe = createStripeMock();
		(stripe.checkout.sessions.retrieve as any).mockResolvedValue({
			id: "cs_test_123",
			status: "complete",
			payment_status: "paid",
			metadata: {
				type: "workshop_registration",
				actor_type: "external",
				workshop_id: "workshop-1",
			},
			customer_details: {
				email: "test@example.com",
				name: "Jane Doe",
				phone: null,
			},
			amount_total: 3500,
			currency: "eur",
		});

		const existingRegistration = {
			id: "registration-1",
			club_activity_id: "workshop-1",
			external_user_id: "external-1",
			member_user_id: null,
			status: "confirmed",
			stripe_checkout_session_id: "cs_test_123",
			amount_paid: 3500,
			currency: "eur",
			registered_at: new Date().toISOString(),
			confirmed_at: new Date().toISOString(),
			cancelled_at: null,
			registration_notes: null,
			created_at: new Date().toISOString(),
			updated_at: new Date().toISOString(),
		};

		const trx = {
			selectFrom: vi.fn().mockReturnValue({
				selectAll: vi.fn().mockReturnValue({
					where: vi.fn().mockReturnValue({
						executeTakeFirst: vi.fn().mockResolvedValue(existingRegistration),
					}),
				}),
			}),
		};

		executeWithRLSMock.mockImplementation(async (_db, _claims, callback) =>
			callback(trx),
		);

		const service = new RegistrationService(
			{} as never,
			createMockSession(),
			{ kind: "system" },
			stripe,
			createMockLogger(),
		);

		vi.spyOn(service as any, "upsertExternalUser").mockResolvedValue(
			"external-1",
		);

		const result =
			await service.completeExternalRegistrationFromCheckoutSession({
				workshopId: "workshop-1",
				checkoutSessionId: "cs_test_123",
			});

		expect(result).toEqual(existingRegistration);
	});
});
