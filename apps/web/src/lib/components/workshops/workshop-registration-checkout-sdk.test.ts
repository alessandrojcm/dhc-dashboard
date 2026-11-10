import { describe, expect, it, vi } from "vitest";
import { redirectingEmbeddedCheckout } from "./workshop-registration-checkout-sdk";

describe("redirectingEmbeddedCheckout (ALE-447)", () => {
	it("passes only the session: the session redirects, so no completion callback", async () => {
		const widget = { mount: vi.fn(), destroy: vi.fn() };
		const initEmbeddedCheckout = vi.fn(async () => widget);
		const load = vi.fn(async () => ({ initEmbeddedCheckout }));

		await expect(
			redirectingEmbeddedCheckout(load)({
				clientSecret: "cs_test_secret",
				onComplete: () => {},
			}),
		).resolves.toBe(widget);
		expect(initEmbeddedCheckout).toHaveBeenCalledWith({
			clientSecret: "cs_test_secret",
		});
	});

	it("fails when Stripe cannot load", async () => {
		await expect(
			redirectingEmbeddedCheckout(async () => null)({
				clientSecret: "cs_test_secret",
			}),
		).rejects.toThrow();
	});
});
