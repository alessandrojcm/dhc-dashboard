import { describe, expect, it } from "vitest";
import type { PlanPricing } from "#lib/types.js";
import type { AcceptanceCookieStore } from "./ports";
import { readInvitationPricing } from "./pricing-query";
import { acceptanceView, inMemoryAcceptanceApi } from "./testing";

// Faithful query-context port: any cookie mutation throws, just as it does
// inside SvelteKit's remote query runtime.
function queryCookies(proof?: string): AcceptanceCookieStore {
	function forbidden(): never {
		throw new Error("remote_cookie_forbidden");
	}
	return {
		readProof: () => proof,
		storeProof: forbidden,
		clearProof: forbidden,
		storeSignInPrefill: forbidden,
	};
}

describe("read-only pricing query", () => {
	it.each(["stale-proof", undefined])(
		"returns a conflict without mutating proof %s",
		async (proof) => {
			const { api, calls } = inMemoryAcceptanceApi({
				previewPricing: acceptanceView("restartVerification", {}, 409),
			});

			await expect(
				readInvitationPricing({ api, cookies: queryCookies(proof) }),
			).rejects.toMatchObject({ status: 409 });
			expect(calls).toEqual(proof ? [{ op: "previewPricing", proof }] : []);
		},
	);

	it("returns pricing and forwards the coupon without cookie writes", async () => {
		const money = { amount: 1000, currency: "EUR" as const, precision: 2 };
		const pricing: PlanPricing = {
			proratedPrice: money,
			proratedMonthlyPrice: money,
			proratedAnnualPrice: money,
			monthlyFee: money,
			annualFee: money,
		};
		const { api, calls } = inMemoryAcceptanceApi({
			previewPricing: { kind: "pricing", pricing },
		});

		await expect(
			readInvitationPricing({ api, cookies: queryCookies("proof") }, "SAVE"),
		).resolves.toEqual(pricing);
		expect(calls).toEqual([
			{ op: "previewPricing", proof: "proof", payload: { code: "SAVE" } },
		]);
	});

	it("preserves upstream rejection details", async () => {
		const { api } = inMemoryAcceptanceApi({
			previewPricing: {
				kind: "rejected",
				httpStatus: 422,
				detail: "Invalid coupon",
			},
		});
		await expect(
			readInvitationPricing({ api, cookies: queryCookies("proof") }),
		).rejects.toMatchObject({
			status: 422,
			body: { message: "Invalid coupon" },
		});
	});

	it("returns an unavailable error without cookie writes", async () => {
		const { api } = inMemoryAcceptanceApi({
			previewPricing: { kind: "unavailable", reason: "timeout" },
		});
		await expect(
			readInvitationPricing({ api, cookies: queryCookies("proof") }),
		).rejects.toMatchObject({ status: 503 });
	});
});
