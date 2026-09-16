import { describe, expect, it } from "vitest";
import { interpretAcceptanceResponse } from "./api-client-adapter";

const response = (status: number) => new Response(null, { status });

describe("interpretAcceptanceResponse", () => {
	it("reads a 200 safe view and normalizes Phoenix's snake_case status", () => {
		expect(
			interpretAcceptanceResponse({
				data: { data: { state: "awaiting_oauth", expiresAt: "2026-01-01" } },
				response: response(200),
			}),
		).toEqual({
			kind: "view",
			httpStatus: 200,
			view: { state: "awaitingDiscord", expiresAt: "2026-01-01" },
		});
	});

	it("reads a safe view carried by a non-2xx error body", () => {
		expect(
			interpretAcceptanceResponse({
				error: { data: { state: "restart_verification" } },
				response: response(409),
			}),
		).toEqual({
			kind: "view",
			httpStatus: 409,
			view: { state: "restartVerification" },
		});
	});

	it("rejects an unknown Phoenix status instead of guessing", () => {
		expect(
			interpretAcceptanceResponse({
				data: { data: { state: "somethingNew" } },
				response: response(200),
			}),
		).toEqual({ kind: "rejected", httpStatus: 200, detail: undefined });
	});

	it("reads the Error schema detail on a rejection", () => {
		expect(
			interpretAcceptanceResponse({
				error: { errors: { detail: "Payment payload is malformed" } },
				response: response(422),
			}),
		).toEqual({
			kind: "rejected",
			httpStatus: 422,
			detail: "Payment payload is malformed",
		});
	});

	it("maps a ky timeout to an unavailable result", () => {
		const timeout = new Error("Request timed out");
		timeout.name = "TimeoutError";

		expect(interpretAcceptanceResponse({ error: timeout })).toEqual({
			kind: "unavailable",
			reason: "timeout",
			detail: "Request timed out",
		});
	});

	it("maps any other transport failure to a network unavailability", () => {
		expect(
			interpretAcceptanceResponse({ error: new TypeError("fetch failed") }),
		).toEqual({
			kind: "unavailable",
			reason: "network",
			detail: "fetch failed",
		});
	});
});
