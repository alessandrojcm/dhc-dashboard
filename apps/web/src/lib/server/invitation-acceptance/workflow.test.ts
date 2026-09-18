import { describe, expect, it } from "vitest";
import {
	continueToPayment,
	previewPricing,
	readInvitationPage,
	restartDiscordVerification,
	resumeInvitationAcceptance,
	submitInvitationPayment,
	verifyInvitationCredentials,
} from "./workflow";
import {
	acceptanceView,
	inMemoryAcceptanceApi,
	recordingCookieStore,
} from "./testing";
import type { PaymentSubmission } from "./ports";

const payment: PaymentSubmission = {
	nextOfKinName: "Grace Hopper",
	nextOfKinPhone: "+353838774532",
	stripeConfirmationToken: "ctoken_123",
	mandateContext: { ipAddress: "127.0.0.1" },
};

const credentials = {
	invitationId: "inv-1",
	email: "invitee@example.com",
	dateOfBirth: "1990-01-01",
};

describe("Invitation Acceptance workflow", () => {
	describe("missing proof", () => {
		it.each([
			["initial page", readInvitationPage],
			["resume", resumeInvitationAcceptance],
			["continue to payment", continueToPayment],
			["pricing", previewPricing],
		])(
			"%s restarts, clears proof, and never calls Phoenix",
			async (_l, run) => {
				const { api, calls } = inMemoryAcceptanceApi();
				const { cookies } = recordingCookieStore();

				const outcome = await run({ api, cookies });

				expect(outcome.type).toBe("RESTART_VERIFICATION");
				expect(outcome.effects).toEqual([{ type: "clearAcceptanceProof" }]);
				expect(calls).toEqual([]);
			},
		);

		it("payment without proof fails terminally and clears proof", async () => {
			const { api, calls } = inMemoryAcceptanceApi();
			const { cookies } = recordingCookieStore();

			const outcome = await submitInvitationPayment({ api, cookies }, payment);

			expect(outcome).toMatchObject({
				type: "PAYMENT_FAILED",
				recoverable: false,
				effects: [{ type: "clearAcceptanceProof" }],
			});
			expect(calls).toEqual([]);
		});
	});

	describe("restartVerification from Phoenix", () => {
		it.each([
			["initial page", readInvitationPage, "show"],
			["resume", resumeInvitationAcceptance, "show"],
			["continue to payment", continueToPayment, "continueAcceptance"],
			["pricing", previewPricing, "previewPricing"],
		] as const)(
			"%s yields the same restart outcome",
			async (_label, run, op) => {
				const { api, calls } = inMemoryAcceptanceApi({
					[op]: acceptanceView("restartVerification", {}, 409),
				});
				const { cookies } = recordingCookieStore({ proof: "proof" });

				const outcome = await run({ api, cookies });

				expect(outcome).toEqual({
					type: "RESTART_VERIFICATION",
					effects: [{ type: "clearAcceptanceProof" }],
				});
				expect(calls).toEqual([{ op, proof: "proof" }]);
			},
		);

		it("payment yields a terminal failure with the same proof-clearing effect", async () => {
			const { api } = inMemoryAcceptanceApi({
				submitPayment: acceptanceView("restartVerification", {}, 409),
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await submitInvitationPayment({ api, cookies }, payment);

			expect(outcome).toMatchObject({
				type: "PAYMENT_FAILED",
				message: "Invitation verification has expired. Please verify again.",
				recoverable: false,
				effects: [{ type: "clearAcceptanceProof" }],
			});
		});

		it("a declined payment that Phoenix already concluded (402 + restartVerification) says the payment failed, not that verification expired", async () => {
			// Phoenix runs cleanup synchronously on a terminal Stripe decline, so
			// the safe view is already `restartVerification`; the 402 status is
			// the only thing that tells a decline apart from a dead handle.
			const { api } = inMemoryAcceptanceApi({
				submitPayment: acceptanceView("restartVerification", {}, 402),
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await submitInvitationPayment({ api, cookies }, payment);

			expect(outcome).toEqual({
				type: "PAYMENT_FAILED",
				message: "Payment could not be completed",
				recoverable: false,
				effects: [{ type: "clearAcceptanceProof" }],
			});
		});
	});

	describe("accepted", () => {
		it.each([
			["initial page", readInvitationPage, "show"],
			["resume", resumeInvitationAcceptance, "show"],
			["continue to payment", continueToPayment, "continueAcceptance"],
		] as const)(
			"%s establishes the handoff and redirects to success exactly once",
			async (_label, run, op) => {
				const { api } = inMemoryAcceptanceApi({
					[op]: acceptanceView("accepted", {
						invitationEmail: "invitee@example.com",
					}),
				});
				const { cookies } = recordingCookieStore({ proof: "proof" });

				const outcome = await run({ api, cookies });

				expect(outcome).toMatchObject({ type: "REDIRECT_TO_SUCCESS" });
				expect(outcome.effects).toEqual([
					{
						type: "establishSignInHandoff",
						invitationEmail: "invitee@example.com",
					},
					{ type: "clearAcceptanceProof" },
				]);
			},
		);

		it("payment success reconciles against Phoenix before redirecting", async () => {
			const { api, calls } = inMemoryAcceptanceApi({
				submitPayment: acceptanceView("accepted", {
					invitationEmail: "invitee@example.com",
				}),
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await submitInvitationPayment({ api, cookies }, payment);

			expect(outcome).toMatchObject({
				type: "REDIRECT_TO_SUCCESS",
				view: { state: "accepted" },
			});
			expect(calls).toEqual([
				{ op: "submitPayment", proof: "proof", payload: payment },
			]);
		});
	});

	describe("paymentPending", () => {
		it("initial page shows the pending state with its retry flag", async () => {
			const { api } = inMemoryAcceptanceApi({
				show: acceptanceView("paymentPending", {
					discordVerified: true,
					retryAllowed: false,
				}),
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await readInvitationPage({ api, cookies });

			expect(outcome).toEqual({
				type: "SHOW",
				view: {
					state: "paymentPending",
					discordVerified: true,
					retryAllowed: false,
				},
				effects: [],
			});
		});

		it("resume retries only when Phoenix allows it and re-decides on the retry result", async () => {
			const { api, calls } = inMemoryAcceptanceApi({
				show: acceptanceView("paymentPending", { retryAllowed: true }),
				retry: acceptanceView("accepted", {
					invitationEmail: "invitee@example.com",
				}),
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await resumeInvitationAcceptance({ api, cookies });

			expect(outcome.type).toBe("REDIRECT_TO_SUCCESS");
			expect(calls.map((call) => call.op)).toEqual(["show", "retry"]);
		});

		it("resume does not retry when Phoenix forbids it", async () => {
			const { api, calls } = inMemoryAcceptanceApi({
				show: acceptanceView("paymentPending", { retryAllowed: false }),
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await resumeInvitationAcceptance({ api, cookies });

			expect(outcome).toMatchObject({
				type: "SHOW",
				view: { state: "paymentPending" },
			});
			expect(calls.map((call) => call.op)).toEqual(["show"]);
		});

		it("resume keeps the payment state when the retry is still pending", async () => {
			const { api } = inMemoryAcceptanceApi({
				show: acceptanceView("paymentNeedsAction", { retryAllowed: true }),
				retry: acceptanceView("paymentPending", { retryAllowed: false }),
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await resumeInvitationAcceptance({ api, cookies });

			expect(outcome).toMatchObject({
				type: "SHOW",
				view: { state: "paymentPending" },
				effects: [],
			});
		});

		it("payment submission that stays pending shows the pending state, not accepted", async () => {
			const { api } = inMemoryAcceptanceApi({
				submitPayment: acceptanceView("paymentPending", { retryAllowed: true }),
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await submitInvitationPayment({ api, cookies }, payment);

			expect(outcome).toMatchObject({
				type: "SHOW",
				view: { state: "paymentPending" },
				effects: [],
			});
		});
	});

	describe("failures", () => {
		it("a terminally rejected payment (402) is a recoverable failure that keeps the proof", async () => {
			const { api } = inMemoryAcceptanceApi({
				submitPayment: acceptanceView("paymentReady", {}, 402),
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await submitInvitationPayment({ api, cookies }, payment);

			expect(outcome).toEqual({
				type: "PAYMENT_FAILED",
				message: "Payment could not be completed",
				recoverable: true,
				effects: [],
			});
		});

		it("a malformed payment payload (422) surfaces the Phoenix detail", async () => {
			const { api } = inMemoryAcceptanceApi({
				submitPayment: {
					kind: "rejected",
					httpStatus: 422,
					detail: "nextOfKinPhone is invalid",
				},
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await submitInvitationPayment({ api, cookies }, payment);

			expect(outcome).toMatchObject({
				type: "PAYMENT_FAILED",
				message: "nextOfKinPhone is invalid",
				recoverable: true,
			});
		});

		it("a timeout during payment is recoverable and keeps the proof", async () => {
			const { api } = inMemoryAcceptanceApi({
				submitPayment: { kind: "unavailable", reason: "timeout" },
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await submitInvitationPayment({ api, cookies }, payment);

			expect(outcome).toMatchObject({
				type: "PAYMENT_FAILED",
				message: expect.stringContaining("taking longer than expected"),
				recoverable: true,
				effects: [],
			});
		});

		it("a scheduled-recovery 503 during payment tells the invitee to wait", async () => {
			const { api } = inMemoryAcceptanceApi({
				submitPayment: {
					kind: "rejected",
					httpStatus: 503,
					detail: "recovery scheduled",
				},
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await submitInvitationPayment({ api, cookies }, payment);

			expect(outcome).toMatchObject({
				type: "PAYMENT_FAILED",
				message: "recovery scheduled",
				recoverable: true,
			});
		});

		it("an unavailable Phoenix on the initial page keeps the proof", async () => {
			const { api } = inMemoryAcceptanceApi({
				show: { kind: "unavailable", reason: "network" },
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await readInvitationPage({ api, cookies });

			expect(outcome).toMatchObject({ type: "UNAVAILABLE", effects: [] });
		});
	});

	describe("verification", () => {
		it("stores the issued proof when Phoenix moves to awaitingDiscord", async () => {
			const { api, calls } = inMemoryAcceptanceApi({
				verify: {
					result: acceptanceView("awaitingDiscord"),
					issuedProof: "issued",
				},
			});
			const { cookies } = recordingCookieStore();

			const outcome = await verifyInvitationCredentials(
				{ api, cookies },
				credentials,
			);

			expect(outcome).toEqual({
				type: "VERIFIED",
				effects: [{ type: "storeProof", proof: "issued" }],
			});
			expect(calls).toEqual([
				{ op: "verify", proof: undefined, payload: credentials },
			]);
		});

		it("forwards an existing proof so Phoenix can resume the live flow", async () => {
			const { api, calls } = inMemoryAcceptanceApi({
				verify: {
					result: acceptanceView("awaitingDiscord"),
					issuedProof: "issued",
				},
			});
			const { cookies } = recordingCookieStore({ proof: "stale" });

			await verifyInvitationCredentials({ api, cookies }, credentials);

			expect(calls[0]?.proof).toBe("stale");
		});

		it("rejects and clears proof when Phoenix answers restart", async () => {
			const { api } = inMemoryAcceptanceApi({
				verify: {
					result: acceptanceView("restartVerification", {}, 422),
					issuedProof: undefined,
				},
			});
			const { cookies } = recordingCookieStore({ proof: "stale" });

			const outcome = await verifyInvitationCredentials(
				{ api, cookies },
				credentials,
			);

			expect(outcome).toEqual({
				type: "REJECTED",
				reason: "restart",
				effects: [{ type: "clearAcceptanceProof" }],
			});
		});

		it("rejects without storing anything when no proof was issued", async () => {
			const { api } = inMemoryAcceptanceApi({
				verify: {
					result: acceptanceView("awaitingDiscord"),
					issuedProof: undefined,
				},
			});
			const { cookies } = recordingCookieStore();

			const outcome = await verifyInvitationCredentials(
				{ api, cookies },
				credentials,
			);

			expect(outcome).toEqual({
				type: "REJECTED",
				reason: "no_proof_issued",
				effects: [],
			});
		});

		it("rejects when Phoenix answers with an unexpected state", async () => {
			const { api } = inMemoryAcceptanceApi({
				verify: {
					result: acceptanceView("paymentReady"),
					issuedProof: "issued",
				},
			});
			const { cookies } = recordingCookieStore();

			const outcome = await verifyInvitationCredentials(
				{ api, cookies },
				credentials,
			);

			expect(outcome).toMatchObject({
				type: "REJECTED",
				reason: "unexpected_state",
				effects: [],
			});
		});
	});

	describe("restart Discord verification", () => {
		it("cancels the Discord claim and clears the proof", async () => {
			const { api, calls } = inMemoryAcceptanceApi({
				cancelDiscord: acceptanceView("restartVerification"),
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await restartDiscordVerification({ api, cookies });

			expect(outcome).toEqual({
				type: "RESTART_VERIFICATION",
				effects: [{ type: "clearAcceptanceProof" }],
			});
			expect(calls).toEqual([{ op: "cancelDiscord", proof: "proof" }]);
		});

		it("still clears the proof when Phoenix cannot be reached", async () => {
			const { api } = inMemoryAcceptanceApi({
				cancelDiscord: { kind: "unavailable", reason: "network" },
			});
			const { cookies } = recordingCookieStore({ proof: "proof" });

			const outcome = await restartDiscordVerification({ api, cookies });

			expect(outcome.effects).toEqual([{ type: "clearAcceptanceProof" }]);
		});

		it("does not call Phoenix without a proof", async () => {
			const { api, calls } = inMemoryAcceptanceApi();
			const { cookies } = recordingCookieStore();

			const outcome = await restartDiscordVerification({ api, cookies });

			expect(outcome.type).toBe("RESTART_VERIFICATION");
			expect(calls).toEqual([]);
		});
	});

	it("pricing success returns the preview and never touches cookies", async () => {
		const pricing = {
			proratedPrice: { amount: 3300, currency: "EUR" as const, precision: 2 },
			proratedMonthlyPrice: {
				amount: 1500,
				currency: "EUR" as const,
				precision: 2,
			},
			proratedAnnualPrice: {
				amount: 1800,
				currency: "EUR" as const,
				precision: 2,
			},
			monthlyFee: { amount: 4200, currency: "EUR" as const, precision: 2 },
			annualFee: { amount: 36000, currency: "EUR" as const, precision: 2 },
		};
		const { api, calls } = inMemoryAcceptanceApi({
			previewPricing: { kind: "pricing", pricing },
		});
		const store = recordingCookieStore({ proof: "proof" });

		const outcome = await previewPricing(
			{ api, cookies: store.cookies },
			"SAVE",
		);

		expect(outcome).toEqual({ type: "PRICING", pricing, effects: [] });
		expect(calls).toEqual([
			{ op: "previewPricing", proof: "proof", payload: { code: "SAVE" } },
		]);
		expect(store.effects).toEqual([]);
		expect(store.proof).toBe("proof");
	});

	it("continue to payment shows paymentReady", async () => {
		const { api } = inMemoryAcceptanceApi({
			continueAcceptance: acceptanceView("paymentReady", {
				complimentary: false,
			}),
		});
		const { cookies } = recordingCookieStore({ proof: "proof" });

		const outcome = await continueToPayment({ api, cookies });

		expect(outcome).toMatchObject({
			type: "SHOW",
			view: { state: "paymentReady" },
		});
	});

	it("workflow functions never touch the cookie store themselves", async () => {
		const { api } = inMemoryAcceptanceApi({
			show: acceptanceView("accepted", { invitationEmail: "a@example.com" }),
		});
		const store = recordingCookieStore({ proof: "proof" });

		await readInvitationPage({ api, cookies: store.cookies });

		expect(store.effects).toEqual([]);
		expect(store.proof).toBe("proof");
	});
});
